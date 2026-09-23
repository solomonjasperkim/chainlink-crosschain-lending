// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Wraps Chainlink Data Feeds for every priced asset in the market and normalizes each answer to
/// 1e18, rejecting a round that is stale, incomplete, or non-positive rather than letting bad data reach
/// the lending logic.
contract PriceFeedOracle is Ownable {
    struct FeedConfig {
        AggregatorV3Interface feed;
        uint256 maxStaleness; // seconds a round is trusted for before being rejected
    }

    mapping(address asset => FeedConfig) public feeds;

    event FeedSet(address indexed asset, address indexed feed, uint256 maxStaleness);

    error FeedNotSet(address asset);
    error InvalidPrice(address asset, int256 answer);
    error IncompleteRound(address asset, uint80 roundId, uint80 answeredInRound);
    error StalePrice(address asset, uint256 updatedAt, uint256 maxStaleness);

    constructor(address initialOwner) Ownable(initialOwner) { }

    function setFeed(address asset, address feed, uint256 maxStaleness) external onlyOwner {
        feeds[asset] = FeedConfig({ feed: AggregatorV3Interface(feed), maxStaleness: maxStaleness });
        emit FeedSet(asset, feed, maxStaleness);
    }

    /// @return price18 `asset`'s USD price, scaled to 1e18 regardless of the underlying feed's decimals.
    function getPrice(address asset) public view returns (uint256 price18) {
        FeedConfig memory cfg = feeds[asset];
        if (address(cfg.feed) == address(0)) revert FeedNotSet(asset);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = cfg.feed.latestRoundData();

        if (answer <= 0) revert InvalidPrice(asset, answer);
        // A round that hasn't finished answering yet carries a stale/incomplete price.
        if (answeredInRound < roundId) revert IncompleteRound(asset, roundId, answeredInRound);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > cfg.maxStaleness) {
            revert StalePrice(asset, updatedAt, cfg.maxStaleness);
        }

        uint8 feedDecimals = cfg.feed.decimals();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 rawPrice = uint256(answer); // safe: `answer <= 0` already reverted above.
        if (feedDecimals < 18) {
            price18 = rawPrice * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            price18 = rawPrice / (10 ** (feedDecimals - 18));
        } else {
            price18 = rawPrice;
        }
    }

    /// @notice USD value (1e18-scaled) of `amount` of an 18-decimal `asset`.
    function usdValue(address asset, uint256 amount) external view returns (uint256) {
        return (amount * getPrice(asset)) / 1e18;
    }
}
