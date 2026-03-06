// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IOracle {
    function addNewPriceFeed(address token, address tokenPriceAggregator, uint256 refreshRateThreshold) external;
    function removeAggregator(address token) external;
    function priceOfTokens(address token, uint256 amount) external view returns (uint256);
}
