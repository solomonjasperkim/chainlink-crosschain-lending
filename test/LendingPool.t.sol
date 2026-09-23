// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MockV3Aggregator } from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PriceFeedOracle } from "../src/PriceFeedOracle.sol";
import { LendingPool } from "../src/LendingPool.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract LendingPoolTest is Test {
    PriceFeedOracle internal oracle;
    MockERC20 internal weth;
    MockERC20 internal dai;
    MockV3Aggregator internal wethFeed;
    MockV3Aggregator internal daiFeed;
    LendingPool internal pool;

    address internal owner = address(this);
    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice");
    address internal liquidator = makeAddr("liquidator");

    uint256 internal constant INITIAL_WETH_PRICE = 2_000e8; // 8-decimal feed, $2000
    uint256 internal constant DAI_PRICE = 1e8; // $1

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH");
        dai = new MockERC20("Dai Stablecoin", "DAI");

        oracle = new PriceFeedOracle(owner);
        wethFeed = new MockV3Aggregator(8, int256(INITIAL_WETH_PRICE));
        daiFeed = new MockV3Aggregator(8, int256(DAI_PRICE));
        oracle.setFeed(address(weth), address(wethFeed), 1 days);
        oracle.setFeed(address(dai), address(daiFeed), 1 days);

        pool = new LendingPool(owner, IERC20(address(weth)), IERC20(address(dai)), oracle);

        dai.mint(lender, 100_000e18);
        vm.startPrank(lender);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(100_000e18);
        vm.stopPrank();

        weth.mint(alice, 100e18);
        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);

        dai.mint(liquidator, 100_000e18);
        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);
    }

    function _depositAndBorrow(address user, uint256 collateralAmount, uint256 borrowAmount) internal {
        vm.startPrank(user);
        pool.depositCollateral(collateralAmount);
        if (borrowAmount > 0) pool.borrow(borrowAmount);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Supply
    // ---------------------------------------------------------------------

    function test_supplyAndWithdrawSupply() public {
        assertEq(pool.totalSupplied(), 100_000e18);
        assertEq(dai.balanceOf(address(pool)), 100_000e18);

        vm.prank(lender);
        pool.withdrawSupply(40_000e18);
        assertEq(pool.totalSupplied(), 60_000e18);
        assertEq(dai.balanceOf(lender), 40_000e18);
    }

    function test_withdrawSupplyRevertsPastAvailableLiquidity() public {
        vm.prank(lender);
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.withdrawSupply(200_000e18);
    }

    // ---------------------------------------------------------------------
    // Collateral & borrowing
    // ---------------------------------------------------------------------

    function test_depositCollateral() public {
        vm.prank(alice);
        pool.depositCollateral(10e18);
        assertEq(pool.collateralBalance(alice), 10e18);
        assertEq(weth.balanceOf(address(pool)), 10e18);
    }

    function test_borrowWithinMaxLtvSucceeds() public {
        // 10 WETH @ $2000 = $20,000 collateral; 75% max LTV => $15,000 max borrow.
        _depositAndBorrow(alice, 10e18, 15_000e18);
        assertEq(pool.debtBalance(alice), 15_000e18);
        assertEq(dai.balanceOf(alice), 15_000e18);
        assertEq(pool.borrowersCount(), 1);
        assertEq(pool.borrowerAt(0), alice);
    }

    function test_borrowPastMaxLtvReverts() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        vm.expectRevert(LendingPool.ExceedsMaxLtv.selector);
        pool.borrow(15_000e18 + 1);
        vm.stopPrank();
    }

    function test_borrowPastAvailableLiquidityReverts() public {
        weth.mint(alice, 1_000e18); // enough collateral value to clear the LTV check on its own
        vm.startPrank(alice);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(1_000e18); // plenty of collateral, but pool only has 100k DAI
        vm.expectRevert(LendingPool.InsufficientLiquidity.selector);
        pool.borrow(200_000e18);
        vm.stopPrank();
    }

    function test_repayReducesDebtAndClearsBorrowerOnFullRepay() public {
        _depositAndBorrow(alice, 10e18, 10_000e18);
        assertEq(pool.borrowersCount(), 1);

        vm.startPrank(alice);
        dai.approve(address(pool), type(uint256).max);
        pool.repay(4_000e18);
        assertEq(pool.debtBalance(alice), 6_000e18);
        assertEq(pool.borrowersCount(), 1);

        pool.repay(6_000e18);
        assertEq(pool.debtBalance(alice), 0);
        assertEq(pool.borrowersCount(), 0);
        vm.stopPrank();
    }

    function test_repayExceedingDebtReverts() public {
        _depositAndBorrow(alice, 10e18, 5_000e18);
        vm.startPrank(alice);
        dai.approve(address(pool), type(uint256).max);
        vm.expectRevert(LendingPool.RepayExceedsDebt.selector);
        pool.repay(5_000e18 + 1);
        vm.stopPrank();
    }

    function test_withdrawCollateralRevertsIfItWouldBreakHealthFactor() public {
        _depositAndBorrow(alice, 10e18, 15_000e18); // maxed out at 75% LTV
        vm.prank(alice);
        vm.expectRevert(LendingPool.ExceedsMaxLtv.selector);
        pool.withdrawCollateral(1e18);
    }

    function test_withdrawCollateralSucceedsWithinSafeMargin() public {
        _depositAndBorrow(alice, 10e18, 5_000e18); // well under max LTV
        vm.prank(alice);
        pool.withdrawCollateral(1e18);
        assertEq(pool.collateralBalance(alice), 9e18);
    }

    function test_depositCollateralForRequiresTrustedDepositor() public {
        address router = makeAddr("router");
        weth.mint(router, 5e18);

        vm.prank(router);
        vm.expectRevert(LendingPool.NotTrustedDepositor.selector);
        pool.depositCollateralFor(alice, 5e18);

        pool.setTrustedDepositor(router, true);
        vm.startPrank(router);
        weth.approve(address(pool), 5e18);
        pool.depositCollateralFor(alice, 5e18);
        vm.stopPrank();

        assertEq(pool.collateralBalance(alice), 5e18);
        assertEq(pool.collateralBalance(router), 0);
    }

    // ---------------------------------------------------------------------
    // Liquidation
    // ---------------------------------------------------------------------

    function test_liquidateRevertsWhenPositionHealthy() public {
        _depositAndBorrow(alice, 10e18, 5_000e18);
        vm.prank(liquidator);
        vm.expectRevert(LendingPool.PositionHealthy.selector);
        pool.liquidate(alice, 1_000e18);
    }

    function test_liquidateSucceedsAfterPriceDropAndPaysBonus() public {
        // $20,000 collateral, $14,000 debt -> healthy (HF ~1.14).
        _depositAndBorrow(alice, 10e18, 14_000e18);
        assertGe(pool.healthFactor(alice), 1e18);

        // Crash WETH to $1500: collateral now $15,000 against $14,000 debt -> HF = 15000*0.8/14000 < 1.
        wethFeed.updateAnswer(1_500e8);
        assertLt(pool.healthFactor(alice), 1e18);
        assertTrue(pool.isLiquidatable(alice));

        uint256 repayAmount = 5_000e18;
        uint256 liquidatorDaiBefore = dai.balanceOf(liquidator);
        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        uint256 borrowerCollateralBefore = pool.collateralBalance(alice);

        vm.prank(liquidator);
        uint256 seized = pool.liquidate(alice, repayAmount);

        assertEq(pool.debtBalance(alice), 14_000e18 - repayAmount);
        assertEq(pool.collateralBalance(alice), borrowerCollateralBefore - seized);
        assertEq(dai.balanceOf(liquidator), liquidatorDaiBefore - repayAmount);
        assertEq(weth.balanceOf(liquidator), liquidatorWethBefore + seized);

        // Seized USD value should be ~10% (the liquidation bonus) above the repaid USD value, at $1500/WETH.
        uint256 seizedUsd = seized * 1_500e18 / 1e18;
        uint256 repaidUsd = repayAmount; // DAI priced at $1
        uint256 expectedSeizedUsd = repaidUsd * 11_000 / 10_000;
        assertApproxEqAbs(seizedUsd, expectedSeizedUsd, 1e15); // integer-rounding tolerance
    }

    function test_fullLiquidationRemovesBorrowerFromSet() public {
        _depositAndBorrow(alice, 10e18, 14_000e18);
        wethFeed.updateAnswer(1_500e8);

        vm.prank(liquidator);
        pool.liquidate(alice, 14_000e18);

        assertEq(pool.debtBalance(alice), 0);
        assertEq(pool.borrowersCount(), 0);
    }

    function test_liquidationCapsSeizureAtAvailableCollateralOnBadDebt() public {
        _depositAndBorrow(alice, 10e18, 14_000e18);
        // Severe crash: collateral now worth far less than the bonus-adjusted seize entitlement.
        wethFeed.updateAnswer(200e8); // 10 WETH -> $2,000 total
        assertTrue(pool.isLiquidatable(alice));

        vm.prank(liquidator);
        uint256 seized = pool.liquidate(alice, 14_000e18);

        assertEq(seized, 10e18); // capped at the borrower's entire collateral balance
        assertEq(pool.collateralBalance(alice), 0);
    }
}
