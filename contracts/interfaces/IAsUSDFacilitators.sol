// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title IAsUSDFacilitators
 * @author Conclave - Beirao
 * @notice Defines the behavior of a AsUSD Facilitator
 */
interface IAsUSDFacilitators {
    /// Events
    event FeesDistributedToTreasury(
        address indexed treasury, address indexed asset, uint256 amount
    );

    /**
     * @notice Distribute fees to treasury.
     */
    function distributeFeesToTreasury() external;
}
