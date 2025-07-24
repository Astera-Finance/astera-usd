// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../DeploymentConstants.sol";
import "contracts/tokens/AsUSD.sol";

contract AsUsdSetPeer is Script, DeploymentConstants {
    function setUp() public {}

    function run() public {
        vm.broadcast();
        AsUSD(asUsd).setPeer(40267, bytes32(uint256(uint160(asUsd))));
    }
}
