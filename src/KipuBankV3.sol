// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20 as IERCSafe} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title KipuBankV3
 * @author Fabian Rivertt
 * @notice A bank that accepts ETH and various ERC20 tokens, swaps them to USDC via Uniswap V2, and stores all user balances in USDC.
 */

contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERCSafe;

    // --- State
    address public immutable USDC; // USDC token address (6 decimals)
    IUniswapV2Router02 public immutable uniswapRouter;
    address public immutable WETH; // from router

    // balances denominated in USDC (6 decimals)
    mapping(address => uint256) private s_usdcBalances;

    // bank cap and totals (both in USDC 6 decimals)
    uint256 private s_bankCapUsd; // e.g. $100k -> 100_000 * 1e6
    uint256 private s_totalUsdDeposited;

    // constants
    uint256 private constant USDC_DECIMALS = 6;
    address public constant NATIVE_ETH_ADDRESS_ZERO = address(0);

    // --- Errors
    error KipuBankV3__AmountMustBeGreaterThanZero();
    error KipuBankV3__TokenAddressCannotBeZero();
    error KipuBankV3__InsufficientBalance(
        uint256 balance,
        uint256 amountToWithdraw
    );
    error KipuBankV3__DepositExceedsBankCap(
        uint256 totalDeposited,
        uint256 cap,
        uint256 depositValue
    );
    error KipuBankV3__TokenMustBe6Decimals(uint8 decimals);
    error KipuBankV3__TransferFailed();
    error KipuBankV3__SwapFailed();

    // --- Events
    event Deposit(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcReceived
    );
    event Withdrawal(
        address indexed user,
        address indexed tokenOut,
        uint256 amountOut
    );
    event BankCapUpdated(uint256 newCap);

    // --- Constructor
    /**
     * @param _router Uniswap V2 router address
     * @param _usdc Address of USDC (6 decimals)
     * @param _initialBankCap Initial bank cap in USDC (6 decimals)
     */
    constructor(address _router, address _usdc, uint256 _initialBankCap) {
        if (_router == address(0) || _usdc == address(0)) {
            revert KipuBankV3__TokenAddressCannotBeZero();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        uniswapRouter = IUniswapV2Router02(_router);
        USDC = _usdc;
        WETH = uniswapRouter.WETH();

        s_bankCapUsd = _initialBankCap;
    }

    // --- Public / External functions ---

    /**
     * @notice Deposit an ERC20 token (could be USDC or any token with direct pair token->USDC on Uniswap V2)
     * If token == USDC -> stored directly.
     * Otherwise, token is swapped to USDC (path [token, USDC]) and the USDC result is credited.
     *
     * User must approve this contract prior to calling (approve token, amount).
     *
     * @param _tokenAddress token to deposit
     * @param _amount amount of tokens to deposit (token decimals)
     */
    function depositERC20(
        address _tokenAddress,
        uint256 _amount
    ) external nonReentrant {
        if (_amount == 0) revert KipuBankV3__AmountMustBeGreaterThanZero();
        if (_tokenAddress == address(0)) {
            revert KipuBankV3__TokenAddressCannotBeZero();
        }

        // If token is USDC -> direct deposit
        if (_tokenAddress == USDC) {
            // ensure USDC decimals = 6
            uint8 decimals = IERC20Metadata(_tokenAddress).decimals();
            if (decimals != USDC_DECIMALS) {
                revert KipuBankV3__TokenMustBe6Decimals(decimals);
            }

            // check cap
            if (s_totalUsdDeposited + _amount > s_bankCapUsd) {
                revert KipuBankV3__DepositExceedsBankCap(
                    s_totalUsdDeposited,
                    s_bankCapUsd,
                    _amount
                );
            }

            // transfer USDC from user
            IERCSafe(_tokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );

            // update state
            s_totalUsdDeposited += _amount;
            s_usdcBalances[msg.sender] += _amount;

            emit Deposit(msg.sender, _tokenAddress, _amount, _amount);
            return;
        }

        // For other ERC20 tokens: swap token -> USDC via Uniswap V2
        // We estimate amountsOut first to check bank cap (use router.getAmountsOut)
        address[] memory path = new address[](2);
        path[0] = _tokenAddress;
        path[1] = USDC;

        uint256[] memory amountsOut;
        // getAmountsOut could revert if pair doesn't exist or path invalid -> bubble up
        amountsOut = uniswapRouter.getAmountsOut(_amount, path);
        uint256 expectedUsdcOut = amountsOut[amountsOut.length - 1];

        // define slippage tolerance (e.g., 0.5%): we set minOut = expected * 0.995
        uint256 minOut = (expectedUsdcOut * 995) / 1000;

        // Ensure bank cap would not be exceeded by the conservative minOut
        if (s_totalUsdDeposited + minOut > s_bankCapUsd) {
            revert KipuBankV3__DepositExceedsBankCap(
                s_totalUsdDeposited,
                s_bankCapUsd,
                minOut
            );
        }

        // Pull tokens from user to this contract
        IERCSafe(_tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );

        // Approve router
        // safeApprove pattern: reset to 0 then set
        IERCSafe(_tokenAddress).approve(address(uniswapRouter), 0);
        IERCSafe(_tokenAddress).approve(address(uniswapRouter), _amount);

        // record USDC balance before swap to measure exact received
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        // do swap
        uint256 deadline = block.timestamp + 300; // 5 minutes
        try
            uniswapRouter.swapExactTokensForTokens(
                _amount,
                minOut,
                path,
                address(this),
                deadline
            )
        returns (uint256[] memory) {
            // success
        } catch {
            revert KipuBankV3__SwapFailed();
        }

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        uint256 usdcReceived = usdcAfter - usdcBefore;

        // Final safety: if actualReceived is 0 -> revert
        if (usdcReceived == 0) revert KipuBankV3__SwapFailed();

        // As we already validated with minOut, it is highly unlikely actual makes cap exceed.
        // Still, check and roll back state (we cannot undo token swap), so we defensively revert to avoid inconsistent state.
        if (s_totalUsdDeposited + usdcReceived > s_bankCapUsd) {
            // This is a safety check: revert to avoid exceeding cap.
            // Note: since we already swapped tokens -> USDC, revert here will revert whole tx and tokens return to user.
            revert KipuBankV3__DepositExceedsBankCap(
                s_totalUsdDeposited,
                s_bankCapUsd,
                usdcReceived
            );
        }

        // Update state
        s_totalUsdDeposited += usdcReceived;
        s_usdcBalances[msg.sender] += usdcReceived;

        emit Deposit(msg.sender, _tokenAddress, _amount, usdcReceived);
    }

    /**
     * @notice Deposit ETH (native). ETH is swapped to USDC with path [WETH, USDC].
     * msg.value must be > 0
     */
    function depositETH() external payable nonReentrant {
        if (msg.value == 0) revert KipuBankV3__AmountMustBeGreaterThanZero();

        // Build path [WETH, USDC]
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // estimate amountsOut
        uint256[] memory amountsOut = uniswapRouter.getAmountsOut(
            msg.value,
            path
        );
        uint256 expectedUsdcOut = amountsOut[amountsOut.length - 1];
        uint256 minOut = (expectedUsdcOut * 995) / 1000;

        // check cap against conservative minOut
        if (s_totalUsdDeposited + minOut > s_bankCapUsd) {
            revert KipuBankV3__DepositExceedsBankCap(
                s_totalUsdDeposited,
                s_bankCapUsd,
                minOut
            );
        }

        // perform swapExactETHForTokens
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        uint256 deadline = block.timestamp + 300;

        try
            uniswapRouter.swapExactETHForTokens{value: msg.value}(
                minOut,
                path,
                address(this),
                deadline
            )
        returns (uint256[] memory) {
            // success
        } catch {
            revert KipuBankV3__SwapFailed();
        }

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        uint256 usdcReceived = usdcAfter - usdcBefore;

        if (usdcReceived == 0) revert KipuBankV3__SwapFailed();

        if (s_totalUsdDeposited + usdcReceived > s_bankCapUsd) {
            revert KipuBankV3__DepositExceedsBankCap(
                s_totalUsdDeposited,
                s_bankCapUsd,
                usdcReceived
            );
        }

        s_totalUsdDeposited += usdcReceived;
        s_usdcBalances[msg.sender] += usdcReceived;

        emit Deposit(
            msg.sender,
            NATIVE_ETH_ADDRESS_ZERO,
            msg.value,
            usdcReceived
        );
    }

    /**
     * @notice Withdraw USDC (only USDC withdrawals are supported; balances are held in USDC).
     * @param _amount The amount of USDC (6 decimals) to withdraw.
     */
    function withdrawUSDC(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert KipuBankV3__AmountMustBeGreaterThanZero();

        uint256 balance = s_usdcBalances[msg.sender];
        if (balance < _amount) {
            revert KipuBankV3__InsufficientBalance(balance, _amount);
        }

        s_usdcBalances[msg.sender] = balance - _amount;
        s_totalUsdDeposited -= _amount;

        // Transfer USDC out
        IERCSafe(USDC).safeTransfer(msg.sender, _amount);

        emit Withdrawal(msg.sender, USDC, _amount);
    }

    // --- Admin / Manager functions ---

    /**
     * @notice Set new bank cap (in USDC 6 decimals)
     * @param _newCapUsd The new bank cap, denominated in USDC (6 decimals).
     */
    function setBankCap(
        uint256 _newCapUsd
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_bankCapUsd = _newCapUsd;
        emit BankCapUpdated(_newCapUsd);
    }

    // --- Views ---
    /**
     * @notice Gets the USDC balance of a specific user.
     * @param _user The address of the user.
     * @return The user's balance in USDC (6 decimals).
     */
    function getUsdcBalance(address _user) external view returns (uint256) {
        return s_usdcBalances[_user];
    }

    /**
     * @notice Gets the current bank cap.
     * @return The cap in USDC (6 decimals).
     */
    function getBankCap() external view returns (uint256) {
        return s_bankCapUsd;
    }

    /**
     * @notice Gets the total amount of USDC currently held by the bank.
     * @return The total deposits in USDC (6 decimals).
     */
    function getTotalUsdDeposited() external view returns (uint256) {
        return s_totalUsdDeposited;
    }

    // Fallback to receive ETH if needed (shouldn't be used except maybe refunds)
    receive() external payable {}
}
