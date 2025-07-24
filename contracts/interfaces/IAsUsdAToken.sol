// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IAToken} from "lib/astera/contracts/interfaces/IAToken.sol";
import {IAsUSDFacilitators} from "./IAsUSDFacilitators.sol";

/**
 * @title IAsUsdAToken
 * @author Conclave - Beirao
 * @notice Defines the basic interface of the AsUsdAToken.
 */
interface IAsUsdAToken is IAToken, IAsUSDFacilitators {
    event SetVariableDebtToken(address asUsdVariableDebtToken);
    event SetReliquaryInfo(address reliquaryAsusdRewarder, uint256 reliquaryAllocation);
    event SetKeeper(address keeper);

    /**
     * @notice Sets a reference to the GHO variable debt token.
     * @param asUsdVariableDebtToken The address of the AsUsdVariableDebtToken contract.
     */
    function setVariableDebtToken(address asUsdVariableDebtToken) external;

    /**
     * @notice Returns the address of the GHO variable debt token.
     * @return The address of the AsUsdVariableDebtToken contract.
     */
    function getVariableDebtToken() external view returns (address);

    /**
     * @notice Sets reliquary information for fee distribution.
     * @param reliquary Reliquary address used for staked asUSD.
     * @param reliquaryAllocation BPS of asUSD fee distributed to staked asUSD.
     */
    function setReliquaryInfo(address reliquary, uint256 reliquaryAllocation) external;

    /**
     * @notice Set keeper address.
     * @param keeper New keeper address.
     */
    function setKeeper(address keeper) external;
}
