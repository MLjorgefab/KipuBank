// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title KipuBank
 * @author Fabian Rivertt
 * @notice A simple bank for depositing and withdrawing ETH with specific limits.
 */
contract KipuBank {
    // State Variables
    
    /// @notice Maps user addresses to their ETH balance.
    mapping(address => uint256) private s_balances;

    /// @notice The maximum amount a user can withdraw in a single transaction.
    uint256 public immutable i_withdrawalThreshold;

    /// @notice The maximum amount of ETH the entire bank can hold.
    uint256 public immutable i_bankCap;

    /// @notice Keeps track of the total number of deposits.
    uint256 public s_totalDeposits;

    /// @notice Keeps track of the total number of withdrawals.
    uint256 public s_totalWithdrawals;

    // Custom Errors

    /// @notice Thrown when a user tries to deposit 0 ETH.
    error KipuBank__ZeroDeposit();
    
    /// @notice Thrown when a deposit would exceed the bank's total capacity.
    /// @param currentBalance The current total ETH held by the bank.
    /// @param depositAmount The amount the user tried to deposit.
    error KipuBank__BankCapExceeded(uint256 currentBalance, uint256 depositAmount);

    /// @notice Thrown when a user tries to withdraw more than their balance.
    /// @param balance The user's current balance.
    /// @param withdrawAmount The amount the user tried to withdraw.
    error KipuBank__InsufficientBalance(uint256 balance, uint256 withdrawAmount);

    /// @notice Thrown when a user tries to withdraw more than the threshold.
    /// @param withdrawAmount The amount the user tried to withdraw.
    /// @param withdrawalThreshold The maximum allowed withdrawal amount.
    error KipuBank__WithdrawalThresholdExceeded(uint256 withdrawAmount, uint256 withdrawalThreshold);

    /// @notice Thrown when an ETH transfer fails for an unknown reason.
    error KipuBank__TransferFailed();

    // Events

    /// @notice Emitted when a user successfully deposits ETH.
    /// @param whoDeposits The address of the depositor.
    /// @param amountDeposited The amount of ETH deposited.
    event Deposited(address indexed whoDeposits, uint256 amountDeposited);

    /// @notice Emitted when a user successfully withdraws ETH.
    /// @param whoWithdraws The address of the withdrawer.
    /// @param amountWithdrawn The amount of ETH withdrawn.
    event Withdrawn(address indexed whoWithdraws, uint256 amountWithdrawn);

    // Modifier

    /**
     * @notice Modifier to check if a requested withdrawal amount is within the allowed threshold.
     * @param _amount The amount to check.
     */
    modifier withinWithdrawalLimit(uint256 _amount) {
        if (_amount > i_withdrawalThreshold) {
            revert KipuBank__WithdrawalThresholdExceeded(_amount, i_withdrawalThreshold);
        }
        _;
    }

    // Functions

    constructor(uint256 _withdrawalThreshold, uint256 _bankCap) {
        i_withdrawalThreshold = _withdrawalThreshold;
        i_bankCap = _bankCap;
    }

    /**
     * @notice Allows a user to deposit ETH into their personal vault.
     * @dev Reverts if the deposit is 0 or if it exceeds the bank's capacity.
     */
    function deposit() external payable {
        // Checks
        if (msg.value == 0) {
            revert KipuBank__ZeroDeposit();
        }
        if (address(this).balance > i_bankCap) {
            revert KipuBank__BankCapExceeded(address(this).balance, msg.value);
        }
        
        // Effects
        s_balances[msg.sender] += msg.value;
        s_totalDeposits += 1;
        
        emit Deposited(msg.sender, msg.value);
    }

    /**
     * @notice Allows a user to withdraw ETH from their personal vault.
     * @param _amount The amount of ETH to withdraw.
     * @dev Follows the checks-effects-interactions pattern.
     */
    function withdraw(uint256 _amount) external withinWithdrawalLimit(_amount) {
        // Checks
        if (_amount > s_balances[msg.sender]) {
            revert KipuBank__InsufficientBalance(s_balances[msg.sender], _amount);
        }
        
        // Effects
        s_balances[msg.sender] -= _amount;
        s_totalWithdrawals += 1;
        
        // Interactions
        (bool success, ) = payable(msg.sender).call{value: _amount}("");
        if (!success) {
            // If the transfer fails, we revert the state changes.
            s_balances[msg.sender] += _amount;
            s_totalWithdrawals -= 1;
            revert KipuBank__TransferFailed();
        }
        
        emit Withdrawn(msg.sender, _amount);
    }
    
    // View & Private Functions

    /**
     * @notice Gets the balance of the message sender.
     * @return The amount of ETH the caller has deposited.
     */
    function getMyBalance() external view returns (uint256) {
        return s_balances[msg.sender];
    }

    /**
     * @notice (Helper) Checks if a user is allowed to withdraw a certain amount.
     * @param _user The address of the user to check.
     * @param _amount The amount to check.
     * @return true if the withdrawal is allowed, false otherwise.
     */
    function _isAllowedToWithdraw(address _user, uint256 _amount) private view returns (bool) {
        return (_amount <= s_balances[_user] && _amount <= i_withdrawalThreshold);
    }
}
