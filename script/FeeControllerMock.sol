// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import {IFeeController} from "lib/Cod3x-Vault/src/interfaces/IFeeController.sol";

contract FeeControllerMock is IFeeController {
    uint16 public managementFeeBPS;

    function fetchManagementFeeBPS() external pure returns (uint16) {
        return 0;
    }

    function updateManagementFeeBPS(uint16 _feeBPS) external {
        revert("NOT SUPPORTED");
    }
}
