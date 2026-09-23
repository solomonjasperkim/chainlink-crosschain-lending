// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MockV3Aggregator } from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import { PriceFeedOracle } from "../src/PriceFeedOracle.sol";

contract PriceFeedOracleTest is Test {
    PriceFeedOracle internal oracle;
    MockV3Aggregator internal feed8; // 8-decimal feed, like real Chainlink USD feeds
    MockV3Aggregator internal feed18;
    address internal asset8 = makeAddr("asset8");
    address internal asset18 = makeAddr("asset18");

    uint256 internal constant MAX_STALENESS = 1 hours;

    function setUp() public {
        oracle = new PriceFeedOracle(address(this));
        feed8 = new MockV3Aggregator(8, 2_000e8); // e.g. ETH/USD @ $2000
        feed18 = new MockV3Aggregator(18, 1e18); // e.g. a stablecoin feed already in 1e18

        oracle.setFeed(asset8, address(feed8), MAX_STALENESS);
        oracle.setFeed(asset18, address(feed18), MAX_STALENESS);
    }

    function test_normalizes8DecimalFeedTo18() public view {
        assertEq(oracle.getPrice(asset8), 2_000e18);
    }

    function test_normalizes18DecimalFeedUnchanged() public view {
        assertEq(oracle.getPrice(asset18), 1e18);
    }

    function test_revertsWhenFeedNotSet() public {
        address unset = makeAddr("unset");
        vm.expectRevert(abi.encodeWithSelector(PriceFeedOracle.FeedNotSet.selector, unset));
        oracle.getPrice(unset);
    }

    function test_revertsOnNonPositiveAnswer() public {
        feed8.updateAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(PriceFeedOracle.InvalidPrice.selector, asset8, int256(0)));
        oracle.getPrice(asset8);
    }

    function test_revertsOnStalePrice() public {
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        vm.expectRevert(
            abi.encodeWithSelector(PriceFeedOracle.StalePrice.selector, asset8, feed8.latestTimestamp(), MAX_STALENESS)
        );
        oracle.getPrice(asset8);
    }

    function test_freshAnswerWithinStalenessWindowSucceeds() public {
        vm.warp(block.timestamp + MAX_STALENESS - 1);
        assertEq(oracle.getPrice(asset8), 2_000e18);
    }

    function test_usdValueScalesByAmount() public view {
        // 1.5 units of an 18-decimal asset priced at $2000 => $3000, scaled to 1e18
        assertEq(oracle.usdValue(asset8, 1.5e18), 3_000e18);
    }

    function test_onlyOwnerCanSetFeed() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        oracle.setFeed(asset8, address(feed8), MAX_STALENESS);
    }
}
