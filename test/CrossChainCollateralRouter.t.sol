// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MockV3Aggregator } from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CCIPLocalSimulator } from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { MockCCIPRouter } from "@chainlink/local/src/vendor/chainlink-ccip/test/mocks/MockRouter.sol";
import { WETH9 } from "@chainlink/local/src/shared/WETH9.sol";
import { LinkToken } from "@chainlink/local/src/shared/LinkToken.sol";
import { BurnMintERC677Helper } from "@chainlink/local/src/ccip/BurnMintERC677Helper.sol";
import { PriceFeedOracle } from "../src/PriceFeedOracle.sol";
import { LendingPool } from "../src/LendingPool.sol";
import { CrossChainCollateralRouter } from "../src/CrossChainCollateralRouter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @notice CCIPLocalSimulator simulates a single local chain sending a CCIP message to itself, so "source"
/// and "destination" here are two separate pool/router deployments on the same local EVM instance, wired
/// together exactly as two real chains would be — this is the standard chainlink-local testing pattern.
contract CrossChainCollateralRouterTest is Test {
    CCIPLocalSimulator internal sim;
    uint64 internal chainSelector;
    IRouterClient internal router;
    LinkToken internal linkToken;
    BurnMintERC677Helper internal collateral; // the token that travels cross-chain

    PriceFeedOracle internal oracleSrc;
    LendingPool internal poolSrc;
    CrossChainCollateralRouter internal routerSrc;

    PriceFeedOracle internal oracleDst;
    MockERC20 internal daiDst;
    LendingPool internal poolDst;
    CrossChainCollateralRouter internal routerDst;

    address internal owner = address(this);
    address internal alice = makeAddr("alice");

    function setUp() public {
        sim = new CCIPLocalSimulator();
        (
            uint64 selector,
            IRouterClient srcRouter,,
            WETH9 wrappedNative,
            LinkToken link,
            BurnMintERC677Helper ccipBnM,
        ) = sim.configuration();
        chainSelector = selector;
        router = srcRouter;
        linkToken = link;
        collateral = ccipBnM;
        wrappedNative; // unused in this test; part of the simulator's config tuple

        MockV3Aggregator collateralFeed = new MockV3Aggregator(8, 2_000e8);

        // "Source" chain: only needs the router deployed, to originate a cross-chain deposit.
        MockERC20 daiSrc = new MockERC20("Dai Stablecoin", "DAI");
        oracleSrc = new PriceFeedOracle(owner);
        oracleSrc.setFeed(address(collateral), address(collateralFeed), 1 days);
        oracleSrc.setFeed(address(daiSrc), address(new MockV3Aggregator(8, 1e8)), 1 days);
        poolSrc = new LendingPool(owner, IERC20(address(collateral)), IERC20(address(daiSrc)), oracleSrc);
        routerSrc = new CrossChainCollateralRouter(
            owner, address(router), address(linkToken), poolSrc, IERC20(address(collateral))
        );

        // "Destination" chain: where the collateral should actually end up credited.
        daiDst = new MockERC20("Dai Stablecoin", "DAI");
        oracleDst = new PriceFeedOracle(owner);
        oracleDst.setFeed(address(collateral), address(collateralFeed), 1 days);
        oracleDst.setFeed(address(daiDst), address(new MockV3Aggregator(8, 1e8)), 1 days);
        poolDst = new LendingPool(owner, IERC20(address(collateral)), IERC20(address(daiDst)), oracleDst);
        routerDst = new CrossChainCollateralRouter(
            owner, address(router), address(linkToken), poolDst, IERC20(address(collateral))
        );
        poolDst.setTrustedDepositor(address(routerDst), true);

        // Wire the peers up, matching how this would be configured across two real chains.
        routerSrc.setDestinationChainAllowed(chainSelector, true);
        routerDst.setSourceAllowed(chainSelector, address(routerSrc), true);

        collateral.drip(alice);
        sim.requestLinkFromFaucet(alice, 5e18);
    }

    function test_depositCollateralCrossChainCreditsDestinationPool() public {
        uint256 amount = collateral.balanceOf(alice);
        assertGt(amount, 0);

        vm.startPrank(alice);
        collateral.approve(address(routerSrc), amount);
        linkToken.approve(address(routerSrc), type(uint256).max);
        bytes32 messageId = routerSrc.depositCollateralCrossChain(chainSelector, address(routerDst), amount);
        vm.stopPrank();

        assertTrue(messageId != bytes32(0));
        assertEq(poolDst.collateralBalance(alice), amount);
        assertEq(collateral.balanceOf(address(poolDst)), amount);
        assertEq(collateral.balanceOf(alice), 0);
    }

    function test_depositCollateralCrossChainRevertsForDisallowedDestination() public {
        uint64 otherSelector = chainSelector + 1;
        vm.startPrank(alice);
        collateral.approve(address(routerSrc), 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(CrossChainCollateralRouter.DestinationNotAllowed.selector, otherSelector)
        );
        routerSrc.depositCollateralCrossChain(otherSelector, address(routerDst), 1e18);
        vm.stopPrank();
    }

    function test_receivingUnallowlistedSourceReverts() public {
        // A second "source" router that was never allowlisted on the destination.
        CrossChainCollateralRouter rogueSrc = new CrossChainCollateralRouter(
            owner, address(router), address(linkToken), poolSrc, IERC20(address(collateral))
        );
        rogueSrc.setDestinationChainAllowed(chainSelector, true);

        collateral.drip(address(this));
        uint256 amount = collateral.balanceOf(address(this));
        collateral.approve(address(rogueSrc), amount);

        // The local router (like the real one) synchronously calls the destination's ccipReceive and
        // wraps any revert from it in ReceiverError — so that's the error that surfaces here, carrying
        // our SourceNotAllowed revert as its raw inner data.
        bytes memory innerRevert = abi.encodeWithSelector(
            CrossChainCollateralRouter.SourceNotAllowed.selector, chainSelector, address(rogueSrc)
        );
        vm.expectRevert(abi.encodeWithSelector(MockCCIPRouter.ReceiverError.selector, innerRevert));
        rogueSrc.depositCollateralCrossChain(chainSelector, address(routerDst), amount);
    }
}
