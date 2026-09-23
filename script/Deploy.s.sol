// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PriceFeedOracle } from "../src/PriceFeedOracle.sol";
import { LendingPool } from "../src/LendingPool.sol";
import { LiquidationAutomation } from "../src/LiquidationAutomation.sol";
import { CrossChainCollateralRouter } from "../src/CrossChainCollateralRouter.sol";

/// @notice Deploys the full stack (oracle, pool, automation upkeep, CCIP router) to whichever chain
/// `--rpc-url` points at. Every address is read from the environment rather than hardcoded, since
/// Chainlink's testnet router/feed addresses do change over time — pull the current ones for your target
/// network from https://docs.chain.link/ccip/directory and https://docs.chain.link/data-feeds/price-feeds/addresses
/// right before you deploy, rather than trusting any address baked into this repo. See README.md for the
/// full walkthrough, including how to wire two deployments together for the cross-chain flow.
///
/// Required env vars:
///   PRIVATE_KEY              deployer key
///   COLLATERAL_TOKEN         ERC20 address used as collateral (must be CCIP-transferable if you want
///                            the cross-chain deposit flow, e.g. a token with a CCIP token pool)
///   DEBT_TOKEN               ERC20 address the pool lends out
///   COLLATERAL_PRICE_FEED    Chainlink Data Feed for collateralToken/USD
///   DEBT_PRICE_FEED          Chainlink Data Feed for debtToken/USD
///   CCIP_ROUTER               this chain's CCIP Router address
///   LINK_TOKEN                this chain's LINK token address
///   PRICE_STALENESS_SECONDS  optional, defaults to 3600
contract Deploy is Script {
    function run()
        external
        returns (
            PriceFeedOracle oracle,
            LendingPool pool,
            LiquidationAutomation automation,
            CrossChainCollateralRouter router
        )
    {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address collateralToken = vm.envAddress("COLLATERAL_TOKEN");
        address debtToken = vm.envAddress("DEBT_TOKEN");
        address collateralFeed = vm.envAddress("COLLATERAL_PRICE_FEED");
        address debtFeed = vm.envAddress("DEBT_PRICE_FEED");
        address ccipRouter = vm.envAddress("CCIP_ROUTER");
        address linkToken = vm.envAddress("LINK_TOKEN");
        uint256 staleness = vm.envOr("PRICE_STALENESS_SECONDS", uint256(3600));

        vm.startBroadcast(deployerKey);

        oracle = new PriceFeedOracle(deployer);
        oracle.setFeed(collateralToken, collateralFeed, staleness);
        oracle.setFeed(debtToken, debtFeed, staleness);

        pool = new LendingPool(deployer, IERC20(collateralToken), IERC20(debtToken), oracle);

        automation = new LiquidationAutomation(deployer, pool);

        router = new CrossChainCollateralRouter(deployer, ccipRouter, linkToken, pool, IERC20(collateralToken));
        pool.setTrustedDepositor(address(router), true);

        vm.stopBroadcast();

        console.log("PriceFeedOracle           :", address(oracle));
        console.log("LendingPool               :", address(pool));
        console.log("LiquidationAutomation     :", address(automation));
        console.log("CrossChainCollateralRouter:", address(router));
        console.log("");
        console.log("Next steps:");
        console.log("1. Register `automation` as a Chainlink Automation upkeep (custom logic) via");
        console.log("   https://automation.chain.link, funded with LINK.");
        console.log("2. Fund `automation`'s liquidation reserve: debtToken.approve + fundReserve(amount).");
        console.log("3. After deploying this same script on a second chain, on EACH side call:");
        console.log("   router.setDestinationChainAllowed(otherChainSelector, true)");
        console.log("   otherRouter.setSourceAllowed(thisChainSelector, address(router), true)");
    }
}
