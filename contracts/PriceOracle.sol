// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interface/IOracle.sol";

/**
 * @title PriceOracle
 * @dev This contract provides a price oracle for tokens using Chainlink price feeds.
 */
contract PriceOracle is IOracle, Ownable {
    using Math for uint256;

    struct PriceFeedConfig {
        AggregatorV3Interface priceFeed;
        uint256               refreshRateThreshold;
    }

    mapping(address => PriceFeedConfig) public mainFeeds;
    mapping(address => PriceFeedConfig) public altFeeds;

    event AggregatorSet(address indexed token, address indexed aggregator);
    event FallbackAggregatorSet(address indexed token, address indexed aggregator);
    event AggregatorRemoved(address indexed token);
    event FallbackAggregatorRemoved(address indexed token);

    constructor() Ownable(msg.sender) {}

    // This function returns the usd price of an amount of the specified token
    function priceOfTokens(address token, uint256 amountWad)
        external
        view
        override
        returns (uint256)
    {
        PriceFeedConfig memory cfg = mainFeeds[token];
        require(address(cfg.priceFeed) != address(0), "No primary aggregator");

        (, int256 answer, , uint256 updatedAt, ) = cfg.priceFeed.latestRoundData();
        require(answer > 0, "Negative price");

        if (
            cfg.refreshRateThreshold == 0 ||
            block.timestamp - updatedAt <= cfg.refreshRateThreshold
        ) {
            return _computeUsdWad(cfg.priceFeed, amountWad);
        }

        PriceFeedConfig memory fb = altFeeds[token];
        require(address(fb.priceFeed) != address(0), "No fallback aggregator");

        (, int256 fbAnswer, , uint256 fbUpdatedAt, ) = fb.priceFeed.latestRoundData();
        require(fbAnswer > 0, "Negative fallback price");
        require(
            fb.refreshRateThreshold == 0 ||
            block.timestamp - fbUpdatedAt <= fb.refreshRateThreshold,
            "Fallback price stale"
        );

        return _computeUsdWad(fb.priceFeed, amountWad);
    }

    // Helper function
    function _computeUsdWad(
        AggregatorV3Interface feed,
        uint256 amountWad
    ) internal view returns (uint256) {
        (, int256 answer, , , ) = feed.latestRoundData();
        require(answer > 0, "Invalid feed answer");

        uint8 feedDecimals = feed.decimals();
        require(feedDecimals <= 18, "Aggregator decimals > 18");

        uint256 scaleFactor = 10 ** (18 - feedDecimals);
        uint256 priceWad    = uint256(answer) * scaleFactor;

        return amountWad.mulDiv(priceWad, 1e18);
    }

    // Sets the primary aggregator for a token.
    function addNewPriceFeed(
        address token,
        address aggregator,
        uint256 refreshRateThreshold
    ) external onlyOwner {
        require(token      != address(0), "Invalid token");
        require(aggregator != address(0), "Invalid aggregator");

        AggregatorV3Interface agg = AggregatorV3Interface(aggregator);
        (, int256 p, , , ) = agg.latestRoundData();
        require(p > 0, "Aggregator price <= 0");
        require(agg.decimals() <= 18, "Aggregator decimals > 18");
        if (address(altFeeds[token].priceFeed) != address(0)) {
            _validateFeedCompatibility(agg, altFeeds[token].priceFeed);
        }
        mainFeeds[token] = PriceFeedConfig({ priceFeed: agg, refreshRateThreshold: refreshRateThreshold });
        emit AggregatorSet(token, aggregator);
    }

    // Sets the fallback aggregator for a token.
    function addNewFallbackPriceFeed(
        address token,
        address aggregator,
        uint256 refreshRateThreshold
    ) external onlyOwner {
        require(token      != address(0), "Invalid token");
        require(aggregator != address(0), "Invalid fallback aggregator");

         AggregatorV3Interface mainAgg = mainFeeds[token].priceFeed;
        require(address(mainAgg) != address(0), "Primary feed missing");

        AggregatorV3Interface agg = AggregatorV3Interface(aggregator);
        (, int256 p, , , ) = agg.latestRoundData();
        require(p > 0, "Fallback price <= 0");
        require(agg.decimals() <= 18, "Fallback decimals > 18");

        _validateFeedCompatibility(mainAgg, agg);

        altFeeds[token] = PriceFeedConfig({ priceFeed: agg, refreshRateThreshold: refreshRateThreshold });
        emit FallbackAggregatorSet(token, aggregator);
    }

    // Removes the fallback aggregator for a token.
    function removeFallbackPriceFeed(address token) external onlyOwner {
        delete altFeeds[token];
        emit FallbackAggregatorRemoved(token);
    }

    // Removes the primary aggregator for a token.
    function removeAggregator(address token) external override onlyOwner {
        delete mainFeeds[token];
        emit AggregatorRemoved(token);
    }

    function _validateFeedCompatibility(
        AggregatorV3Interface a,
        AggregatorV3Interface b
    ) internal view {
        require(a.decimals() == b.decimals(), "Feed decimals mismatch");

        // `description()` is present on AggregatorV3Interface (>=0.8)
        string memory descA = a.description();
        string memory descB = b.description();
        require(
            keccak256(bytes(descA)) == keccak256(bytes(descB)),
            "Feed asset mismatch"
        );
    }
}
