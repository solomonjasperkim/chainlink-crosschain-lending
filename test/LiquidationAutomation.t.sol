// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MockV3Aggregator } from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PriceFeedOracle } from "../src/PriceFeedOracle.sol";
import { LendingPool } from "../src/LendingPool.sol";
import { LiquidationAutomation } from "../src/LiquidationAutomation.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract LiquidationAutomationTest is Test {
    PriceFeedOracle internal oracle;
    MockERC20 internal weth;
    MockERC20 internal dai;
    MockV3Aggregator internal wethFeed;
    LendingPool internal pool;
    LiquidationAutomation internal automation;

    address internal owner = address(this);
    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH");
        dai = new MockERC20("Dai Stablecoin", "DAI");

        oracle = new PriceFeedOracle(owner);
        wethFeed = new MockV3Aggregator(8, 2_000e8);
        MockV3Aggregator daiFeed = new MockV3Aggregator(8, 1e8);
        oracle.setFeed(address(weth), address(wethFeed), 1 days);
        oracle.setFeed(address(dai), address(daiFeed), 1 days);

        pool = new LendingPool(owner, IERC20(address(weth)), IERC20(address(dai)), oracle);
        automation = new LiquidationAutomation(owner, pool);

        dai.mint(lender, 200_000e18);
        vm.startPrank(lender);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(200_000e18);
        vm.stopPrank();

        weth.mint(alice, 10e18);
        vm.startPrank(alice);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(10e18);
        pool.borrow(14_000e18); // $20,000 collateral, safely under 75% LTV
        vm.stopPrank();

        weth.mint(bob, 5e18);
        vm.startPrank(bob);
        weth.approve(address(pool), type(uint256).max);
        pool.depositCollateral(5e18);
        pool.borrow(1_000e18); // small, stays safe even after the price drop below
        vm.stopPrank();

        dai.mint(owner, 50_000e18);
        dai.approve(address(automation), 50_000e18);
        automation.fundReserve(50_000e18);
    }

    function test_checkUpkeepFindsNothingWhilePositionsAreHealthy() public {
        (bool upkeepNeeded,) = automation.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_checkUpkeepReturnsFalseWithEmptyReserve() public {
        vm.prank(owner);
        automation.withdrawReserve(50_000e18);
        wethFeed.updateAnswer(1_500e8); // would otherwise make alice liquidatable
        (bool upkeepNeeded,) = automation.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_checkUpkeepFindsUnsafePositionAfterPriceDrop() public {
        wethFeed.updateAnswer(1_500e8); // alice's position becomes unsafe; bob's stays safe
        (bool upkeepNeeded, bytes memory performData) = automation.checkUpkeep("");
        assertTrue(upkeepNeeded);

        (address borrower, uint256 repayAmount) = abi.decode(performData, (address, uint256));
        assertEq(borrower, alice);
        assertEq(repayAmount, 14_000e18); // reserve (50k) covers the full debt
    }

    function test_performUpkeepLiquidatesTargetAndKeepsCollateral() public {
        wethFeed.updateAnswer(1_500e8);
        (, bytes memory performData) = automation.checkUpkeep("");

        automation.performUpkeep(performData);

        assertEq(pool.debtBalance(alice), 0);
        assertFalse(pool.isLiquidatable(alice));

        uint256 seized = weth.balanceOf(address(automation));
        assertGt(seized, 0);

        uint256 ownerWethBefore = weth.balanceOf(owner);
        automation.withdrawSeizedCollateral(seized);
        assertEq(weth.balanceOf(address(automation)), 0);
        assertEq(weth.balanceOf(owner), ownerWethBefore + seized);
    }

    function test_performUpkeepRevertsOnStaleTarget() public {
        // alice's position never becomes unsafe here, so this performData is stale/fabricated.
        bytes memory performData = abi.encode(alice, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(LiquidationAutomation.StaleTarget.selector, alice));
        automation.performUpkeep(performData);
    }

    function test_onlyOwnerCanWithdrawReserveOrSeizedCollateral() public {
        vm.startPrank(makeAddr("notOwner"));
        vm.expectRevert();
        automation.withdrawReserve(1e18);
        vm.expectRevert();
        automation.withdrawSeizedCollateral(1e18);
        vm.stopPrank();
    }
}
