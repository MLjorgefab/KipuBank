// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Test, console} from "forge-std/Test.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract KipuBankV3Test is Test {
    KipuBankV3 internal bank;
    IERC20 internal usdc;
    IERC20 internal weth;

    // --- Sepolia Addresses ---
    address internal constant ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    address internal constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal WETH_ADDRESS;

    // --- Test Config ---
    uint256 internal constant INITIAL_CAP = 10_000_000 * 1e6; // $10M Cap
    address internal constant USER = address(0x1);
    address internal constant USDC_WHALE = 0xf89d7b9c864f589bbF53a82105107622B35EaA40;

    function setUp() public {
        bank = new KipuBankV3(ROUTER, USDC, INITIAL_CAP);
        usdc = IERC20(USDC);
        WETH_ADDRESS = bank.WETH();
        weth = IERC20(WETH_ADDRESS);

        uint256 usdcToDeal = 10_000 * 1e6;
        deal(USDC, USER, usdcToDeal);
        vm.deal(USER, 10 ether);

        // El USER aprueba el banco
        vm.startPrank(USER);
        usdc.approve(address(bank), type(uint256).max);
        weth.approve(address(bank), type(uint256).max);
        vm.stopPrank();
    }

    function test_InitialState() public {
        assertEq(bank.USDC(), USDC);
        assertEq(address(bank.uniswapRouter()), ROUTER);
        assertEq(bank.WETH(), WETH_ADDRESS);
        assertEq(bank.getBankCap(), INITIAL_CAP);
    }

    function test_DepositUSDC() public {
        uint256 depositAmount = 1_000 * 1e6; // $1,000

        vm.startPrank(USER);
        bank.depositERC20(USDC, depositAmount);
        vm.stopPrank();

        assertEq(bank.getUsdcBalance(USER), depositAmount);
        assertEq(bank.getTotalUsdDeposited(), depositAmount);
        assertEq(usdc.balanceOf(address(bank)), depositAmount);
    }

    function test_DepositETH() public {
        uint256 depositAmount = 1 ether;

        vm.startPrank(USER);
        bank.depositETH{value: depositAmount}();
        vm.stopPrank();

        uint256 usdcBalance = bank.getUsdcBalance(USER);
        assertTrue(usdcBalance > 0);
        assertEq(bank.getTotalUsdDeposited(), usdcBalance);
        assertEq(usdc.balanceOf(address(bank)), usdcBalance);
    }

    function test_WithdrawUSDC() public {
        uint256 depositAmount = 1_000 * 1e6;
        vm.startPrank(USER);
        bank.depositERC20(USDC, depositAmount);
        vm.stopPrank();

        assertEq(bank.getUsdcBalance(USER), depositAmount);

        uint256 withdrawAmount = 400 * 1e6;
        uint256 userBalanceBefore = usdc.balanceOf(USER);

        vm.startPrank(USER);
        bank.withdrawUSDC(withdrawAmount);
        vm.stopPrank();

        assertEq(bank.getUsdcBalance(USER), depositAmount - withdrawAmount);
        assertEq(bank.getTotalUsdDeposited(), depositAmount - withdrawAmount);
        assertEq(usdc.balanceOf(USER), userBalanceBefore + withdrawAmount);
    }

    function test_Fail_WithdrawTooMuch() public {
        uint256 depositAmount = 100 * 1e6;
        vm.startPrank(USER);
        bank.depositERC20(USDC, depositAmount);
        vm.stopPrank();

        uint256 withdrawAmount = 101 * 1e6;

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(KipuBankV3.KipuBankV3__InsufficientBalance.selector, depositAmount, withdrawAmount)
        );
        bank.withdrawUSDC(withdrawAmount);
        vm.stopPrank();
    }

    function test_Fail_ExceedBankCap_WithUSDC() public {
        bank.setBankCap(1000 * 1e6); // $1,000 Cap

        uint256 depositAmount = 1001 * 1e6;

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(KipuBankV3.KipuBankV3__DepositExceedsBankCap.selector, 0, 1000 * 1e6, depositAmount)
        );
        bank.depositERC20(USDC, depositAmount);
        vm.stopPrank();
    }
}
