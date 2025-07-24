// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../DeploymentConstants.sol";
import "contracts/tokens/AsUSD.sol";

contract AsUsdSetLimits is Script, DeploymentConstants {
    function setUp() public {}

    function run() public {
        uint32 eid_ = 40267;

        vm.startBroadcast();
        AsUSD(asUsd).setBalanceLimit(eid_, -10_000e18);
        AsUSD(asUsd).setHourlyLimit(1000e18);
    }
}
