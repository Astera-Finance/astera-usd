// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../DeploymentConstants.sol";
import "contracts/tokens/CdxUSD.sol";

contract CdxUsdSetLimits is Script, DeploymentConstants {
    function setUp() public {}

    function run() public {
        uint32 eid_ = 40267;

        vm.startBroadcast();
        CdxUSD(cdxUsd).setBalanceLimit(eid_, -10_000e18);
        CdxUSD(cdxUsd).setHourlyLimit(1000e18);
    }
}
