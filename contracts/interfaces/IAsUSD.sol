// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IOFTExtended} from "./IOFTExtended.sol";

interface IAsUSD is IOFTExtended {
    // ======================= Errors ================================

    error AsUSD__INVALID_MINT_AMOUNT();
    error AsUSD__INVALID_BURN_AMOUNT();
    error AsUSD__FACILITATOR_BUCKET_CAPACITY_EXCEEDED();
    error AsUSD__FACILITATOR_ALREADY_EXISTS();
    error AsUSD__INVALID_LABEL();
    error AsUSD__FACILITATOR_DOES_NOT_EXIST();
    error AsUSD__FACILITATOR_BUCKET_LEVEL_NOT_ZERO();

    // ================================== Events ===================================

    event FacilitatorAdded(
        address indexed facilitatorAddress, bytes32 indexed label, uint256 bucketCapacity
    );
    event FacilitatorRemoved(address indexed facilitatorAddress);
    event FacilitatorBucketCapacityUpdated(
        address indexed facilitatorAddress, uint256 oldCapacity, uint256 newCapacity
    );
    event FacilitatorBucketLevelUpdated(
        address indexed facilitatorAddress, uint256 oldLevel, uint256 newLevel
    );

    // ======================= Structs ================================

    struct Facilitator {
        uint128 bucketCapacity;
        uint128 bucketLevel;
        string label;
    }

    // ======================= Interfaces ================================

    function mint(address account, uint256 amount) external;

    function burn(uint256 amount) external;

    function addFacilitator(
        address facilitatorAddress,
        string calldata facilitatorLabel,
        uint128 bucketCapacity
    ) external;

    function removeFacilitator(address facilitatorAddress) external;

    function setFacilitatorBucketCapacity(address facilitator, uint128 newCapacity) external;

    function getFacilitator(address facilitator) external view returns (Facilitator memory);

    function getFacilitatorBucket(address facilitator) external view returns (uint256, uint256);

    function getFacilitatorsList() external view returns (address[] memory);
}
