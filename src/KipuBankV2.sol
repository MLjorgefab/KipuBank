// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author Fabian Rivertt
 * @notice A multi-token (ERC20 AND ETH) bank with access control.
 */

contract KipuBankV2 is AccessControl {
    // --- State Variables ---
    AggregatorV3Interface private immutable i_priceFeed;

    mapping(address => mapping(address => uint256)) private s_balances;
    mapping(address => bool) private s_allowedTokens;
    uint256 private s_bankCapUsd;
    uint256 private s_totalUsdDeposited;
    address public constant NATIVE_ETH_ADDRESS_ZERO = address(0);
    bytes32 public constant TOKEN_MANAGER_ROLE = bytes32(keccak256("TOKEN_MANAGER_ROLE"));

    // --- Errors ---
    error KipuBankV2__AmountMustBeGreaterThanZero();
    error KipuBankV2__TokenAddressCannotBeZero();
    error KipuBankV2__TokenNotAllowed(address tokenAddress);
    error KipuBankV2__TransferFailed();
    error KipuBankV2__InsufficientBalance(uint256 balance, uint256 amountToWithdraw);
    error KipuBankV2__DepositExceedsBankCap(uint256 totalDeposited, uint256 cap, uint256 depositValue);
    error KipuBankV2__TokenMustBe6Decimals(uint8 decimals);

    // --- Events ---
    /**
     * @notice Emitted when a user deposits funds (ETH or ERC20)
     */
    event Deposit(address indexed user, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a user withdraws funds (ETH or ERC20)
     */
    event Withdrawal(address indexed user, address indexed token, uint256 amount);

    /**
     * @notice Emitted when the status of a token is changed by a manager
     */
    event TokenAllowedStatusChanged(address indexed token, bool isAllowed);

    /**
     * @param _priceFeedAddress Chainlink's price address (ETH/USD).
     */
    constructor(address _priceFeedAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TOKEN_MANAGER_ROLE, msg.sender);
        i_priceFeed = AggregatorV3Interface(_priceFeedAddress);
    }

    /**
     * @notice Allows users to deposit allowed ERC20 tokens.
     * @dev User must have approved the contract to spend tokens
     * on their behalf *before* calling this function.
     * @param _tokenAddress The address of the ERC20 token contract.
     * @param _amount The amount of tokens to deposit.
     */
    function depositERC20(address _tokenAddress, uint256 _amount) external {
        // --- Checks ---
        if (_amount <= 0) {
            revert KipuBankV2__AmountMustBeGreaterThanZero();
        }
        if (s_allowedTokens[_tokenAddress] == false) {
            revert KipuBankV2__TokenNotAllowed(_tokenAddress);
        }
        uint8 decimals = IERC20Metadata(_tokenAddress).decimals();
        if (decimals != 6) {
            revert KipuBankV2__TokenMustBe6Decimals(decimals);
        }
        uint256 depositUsdValue = _amount;

        if (s_totalUsdDeposited + depositUsdValue > s_bankCapUsd) {
            revert KipuBankV2__DepositExceedsBankCap(s_totalUsdDeposited, s_bankCapUsd, depositUsdValue);
        }

        // --- Interaction ---
        bool success = IERC20(_tokenAddress).transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert KipuBankV2__TransferFailed();
        }

        // --- Effects ---
        s_totalUsdDeposited += depositUsdValue;
        s_balances[msg.sender][_tokenAddress] += _amount;
        emit Deposit(msg.sender, _tokenAddress, _amount);
    }

    /**
     * @notice Allows users to deposit native ETH.
     * @dev The address(0) is used to represent native ETH
     * in the balance mapping.
     */
    function depositETH() external payable {
        // Check
        if (msg.value <= 0) {
            revert KipuBankV2__AmountMustBeGreaterThanZero();
        }
        uint256 depositUsdValue = getEthAmountInUsd(msg.value);
        if (s_totalUsdDeposited + depositUsdValue > s_bankCapUsd) {
            revert KipuBankV2__DepositExceedsBankCap(s_totalUsdDeposited, s_bankCapUsd, depositUsdValue);
        }
        // Effect
        s_totalUsdDeposited += depositUsdValue;
        s_balances[msg.sender][NATIVE_ETH_ADDRESS_ZERO] += msg.value;
        emit Deposit(msg.sender, NATIVE_ETH_ADDRESS_ZERO, msg.value);
    }

    /**
     * @notice Allows the user to withdraw their deposited native ETH.
     * @param _amount The amount of ETH to withdraw.
     */
    function withdrawETH(uint256 _amount) external {
        // Checks
        if (_amount <= 0) {
            revert KipuBankV2__AmountMustBeGreaterThanZero();
        }

        uint256 balance = s_balances[msg.sender][NATIVE_ETH_ADDRESS_ZERO];
        if (balance < _amount) {
            revert KipuBankV2__InsufficientBalance(balance, _amount);
        }

        // Effects
        s_balances[msg.sender][NATIVE_ETH_ADDRESS_ZERO] -= _amount;
        uint256 withdrawUsdValue = getEthAmountInUsd(_amount);
        s_totalUsdDeposited -= withdrawUsdValue;
        emit Withdrawal(msg.sender, NATIVE_ETH_ADDRESS_ZERO, _amount);

        // Interaction
        (bool sent,) = msg.sender.call{value: _amount}("");
        if (!sent) {
            revert KipuBankV2__TransferFailed();
        }
    }

    /**
     * @notice Allows the user to withdraw their deposited ERC20 tokens.
     * @param _tokenAddress The address of the ERC20 token to withdraw.
     * @param _amount The amount of the token to withdraw.
     */
    function withdrawERC20(address _tokenAddress, uint256 _amount) external {
        // Checks
        if (_amount <= 0) {
            revert KipuBankV2__AmountMustBeGreaterThanZero();
        }

        uint256 balance = s_balances[msg.sender][_tokenAddress];
        if (balance < _amount) {
            revert KipuBankV2__InsufficientBalance(balance, _amount);
        }

        uint8 decimals = IERC20Metadata(_tokenAddress).decimals();
        if (decimals != 6) {
            revert KipuBankV2__TokenMustBe6Decimals(decimals);
        }

        // Effects
        s_balances[msg.sender][_tokenAddress] = balance - _amount;
        uint256 withdrawUsdValue = _amount;
        s_totalUsdDeposited -= withdrawUsdValue;
        emit Withdrawal(msg.sender, _tokenAddress, _amount);

        // Interaction
        bool success = IERC20(_tokenAddress).transfer(msg.sender, _amount);
        if (!success) {
            revert KipuBankV2__TransferFailed();
        }
    }

    // --- Administrative Functions ---

    /**
     * @notice Sets the total USD value the bank can hold.
     * @dev Only callable by the DEFAULT_ADMIN_ROLE.
     * @param _newCapUsd The new cap (in USD, with 6 decimals).
     * E.g., for $100,000, pass 100000 * 10**6
     */
    function setBankCap(uint256 _newCapUsd) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_bankCapUsd = _newCapUsd;
    }

    /**
     * @notice Allows a token manager to add a new token
     * to the list of allowed tokens.
     * @param _tokenAddress The ERC20 token contract address.
     */
    function addAllowedToken(address _tokenAddress) external onlyRole(TOKEN_MANAGER_ROLE) {
        if (_tokenAddress == NATIVE_ETH_ADDRESS_ZERO) {
            revert KipuBankV2__TokenAddressCannotBeZero();
        }
        s_allowedTokens[_tokenAddress] = true;
        emit TokenAllowedStatusChanged(_tokenAddress, true);
    }

    /**
     * @notice Allows a token manager to remove a token
     * from the list of allowed tokens.
     * @param _tokenAddress The ERC20 token contract address.
     */

    function removeAllowedToken(address _tokenAddress) external onlyRole(TOKEN_MANAGER_ROLE) {
        s_allowedTokens[_tokenAddress] = false;
        emit TokenAllowedStatusChanged(_tokenAddress, false);
    }

    /**
     * @notice Allows the default admin to grant the
     * TOKEN_MANAGER_ROLE to a new address.
     * @param _newManager The address that will receive the role.
     */
    function grantTokenManagerRole(address _newManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(TOKEN_MANAGER_ROLE, _newManager);
    }

    // --- View & Pure Functions ---
    /**
     * @notice Gets the latest price from the Chainlink price feed.
     * @dev Returns price and decimals (e.g., 250000000000, 8)
     */
    function getPriceFeedData() public view returns (int256, uint8) {
        (, int256 price,,,) = i_priceFeed.latestRoundData();
        uint8 decimals = i_priceFeed.decimals();
        return (price, decimals);
    }

    /**
     * @notice Converts an amount of ETH (18 decimals) to its
     * USD value (6 decimals).
     * @param _ethAmount The amount of ETH (wei).
     * @return The value in USD (with 6 decimals).
     */
    function getEthAmountInUsd(uint256 _ethAmount) internal view returns (uint256) {
        (int256 price, uint8 decimals) = getPriceFeedData();
        // Verification
        require(decimals == 8, "Oracle must have 8 decimals");
        require(price > 0, "Price must be > 0");

        // (ETH Amount (18) * ETH Price (8)) / 1e20 = USD Value (6)
        return (uint256(price) * _ethAmount) / 1e20;
    }

    /**
     * @notice Gets the deposited balance of a specific token for a user.
     * @param _user The address of the user.
     * @param _tokenAddress The address of the token
     * (use address(0) for native ETH).
     * @return The balance.
     */
    function getBalance(address _user, address _tokenAddress) external view returns (uint256) {
        return s_balances[_user][_tokenAddress];
    }
}
