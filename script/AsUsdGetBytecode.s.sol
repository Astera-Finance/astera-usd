// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import "forge-std/console2.sol";
import "./DeploymentConstants.sol";
import "contracts/tokens/AsUSD.sol";

contract AsUsdGetBytecode is Script, DeploymentConstants {
    string public name = "Astera USD";
    string public symbol = "asUSD";
    address public delegate = admin; // testnet address
    address public treasury = admin; // testnet address
    address public guardian = admin; // testnet address

    function setUp() public {}

    function run() public {
        // Let's do the same thing with `getCode`
        bytes memory args = abi.encode(name, symbol, endpoint, delegate, treasury, guardian);
        bytes memory bytecode = abi.encodePacked(vm.getCode("AsUSD.sol:AsUSD"), args);

        console2.logBytes(bytecode);
    }
}
