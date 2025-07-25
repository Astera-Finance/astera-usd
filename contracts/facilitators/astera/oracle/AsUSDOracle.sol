// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IAggregatorV3Interface} from "contracts/interfaces/IAggregatorV3Interface.sol";

/**
 * @title AsUsdOracle
 * @notice A price feed oracle for AsUSD that maintains a fixed 1:1 peg to USD.
 * @dev Implements a Chainlink-compatible interface with 8 decimal precision. The price is hardcoded
 * to 1 USD.
 * @author Conclave - Beirao
 */
contract AsUsdOracle is IAggregatorV3Interface {
    /// @dev The fixed price of 1 AsUSD in USD, with 8 decimal precision (1.00000000).
    int256 public constant ASUSD_PRICE = 1e8;

    /**
     * @notice Gets the current AsUSD/USD price.
     * @dev Returns the fixed 1 USD price with 8 decimal precision. This price never changes.
     * @return The fixed price of 1 AsUSD in USD terms, formatted with 8 decimals.
     */
    function latestAnswer() external pure returns (int256) {
        return ASUSD_PRICE;
    }

    /**
     * @notice Gets the latest round data in Chainlink oracle format.
     * @dev Most fields are fixed values since price never changes. Only updatedAt varies with time.
     * @return roundId Always returns 1 since price is static.
     * @return answer The fixed AsUSD price of 1 USD with 8 decimals.
     * @return startedAt Always returns 1 since rounds are not tracked.
     * @return updatedAt Current block timestamp to maintain Chainlink compatibility.
     * @return answeredInRound Always returns 0 since historical rounds are not tracked.
     */
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, ASUSD_PRICE, 1, block.timestamp, 0);
    }

    /**
     * @notice Gets the number of decimal places in the price feed.
     * @dev Fixed at 8 decimals to match Chainlink's USD price feed format.
     * @return The number of decimal places (8).
     */
    function decimals() external pure returns (uint8) {
        return 8;
    }

    /**
     * @notice Returns a description of the price feed.
     */
    function description() external view returns (string memory) {
        return "AsUSD/USD";
    }

    /**
     * @notice Returns the version number of the oracle.
     */
    function version() external view returns (uint256) {
        return 1;
    }

    /**
     * @dev This function always reverts with "NOT_IMPLEMENTED".
     */
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        revert("NOT_IMPLEMENTED");
    }
}
