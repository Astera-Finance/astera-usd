// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {DeploymentFixtures, IERC20} from "./DeploymentFixtures.s.sol";
import {UnusedToken} from "./UnusedToken.sol";
import {Reliquary} from "contracts/staking_module/reliquary/Reliquary.sol";
import {LinearPlateauCurve} from "contracts/staking_module/reliquary/curves/LinearPlateauCurve.sol";
import {NFTDescriptor} from "contracts/staking_module/reliquary/nft_descriptors/NFTDescriptor.sol";
import {ParentRollingRewarder} from
    "contracts/staking_module/reliquary/rewarders/ParentRollingRewarder.sol";
import {RollingRewarder} from "contracts/staking_module/reliquary/rewarders/RollingRewarder.sol";
import {ICurves} from "contracts/interfaces/ICurves.sol";

import {console2} from "forge-std/console2.sol";

contract DeployReliquary is Script, DeploymentFixtures {
    uint256 constant SLOPE = 100;
    uint256 constant MIN_MULTIPLIER = 365 days * 100;
    uint256 constant PLATEAU = 10 days;
    string constant RELIQUARY_NAME = "Reliquary sasUsd";
    string constant RELIQUARY_SYMBOL = "sasUsd Relic";
    string constant RELIQUARY_POOL_NAME = "sasUsd Pool";

    address STABLE_POOL = address(1); // fill with real stable pool !!

    /**
     * @dev use this function ONLY for DeployAll.s.sol
     */
    function initStablePool(address _stablePool) public {
        STABLE_POOL = _stablePool;
    }

    function writeJsonData(
        address reliquary,
        address linearPlateauCurve,
        address nftDescriptor,
        address parentRewarder,
        address rewarder,
        string memory path
    ) internal {
        // Serialize main contract addresses
        vm.serializeAddress("reliquaryDeployment", "reliquary", reliquary);
        vm.serializeAddress("reliquaryDeployment", "linearPlateauCurve", linearPlateauCurve);
        vm.serializeAddress("reliquaryDeployment", "nftDescriptor", nftDescriptor);
        vm.serializeAddress("reliquaryDeployment", "parentRewarder", parentRewarder);
        string memory output = vm.serializeAddress("reliquaryDeployment", "rewarder", rewarder);

        // Write to file
        vm.writeJson(output, path);
        console2.log("RELIQUARY DEPLOYED (check addresses at %s)", path);
    }

    /// ========= Reliquary Deploy =========
    function run() public returns (address, address, address, address, address) {
        address REWARD_TOKEN = address(new UnusedToken());

        console2.log("====== Reliquary Deployment ======");
        initializeConstants();
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console2.log("Deployer address: ", deployer);

        vm.startBroadcast(pk);
        Reliquary reliquary = new Reliquary(REWARD_TOKEN, 0, RELIQUARY_NAME, RELIQUARY_SYMBOL);
        address linearPlateauCurve = address(new LinearPlateauCurve(SLOPE, MIN_MULTIPLIER, PLATEAU));

        address nftDescriptor = address(new NFTDescriptor(address(reliquary)));
        address parentRewarder = address(new ParentRollingRewarder());
        Reliquary(address(reliquary)).grantRole(keccak256("OPERATOR"), multisignAdmin);
        Reliquary(address(reliquary)).grantRole(keccak256("GUARDIAN"), multisignGuardian);

        Reliquary(address(reliquary)).grantRole(keccak256("EMISSION_RATE"), multisignGuardian);

        console2.log("====== Adding Pool to Reliquary ======");
        IERC20(STABLE_POOL).approve(address(reliquary), 1); // approve 1 wei to bootstrap the pool
        reliquary.addPool(
            100, // alloc point - only one pool is necessary
            address(STABLE_POOL), // BTP
            address(parentRewarder),
            ICurves(linearPlateauCurve),
            RELIQUARY_POOL_NAME,
            nftDescriptor,
            true, // allowPartialWithdrawals
            deployer // can send to the strategy directly.
        );

        RollingRewarder rewarder =
            RollingRewarder(ParentRollingRewarder(parentRewarder).createChild(address(asUsd)));

        Reliquary(address(reliquary)).grantRole(keccak256("DEFAULT_ADMIN_ROLE"), multisignAdmin);
        Reliquary(address(reliquary)).revokeRole(keccak256("DEFAULT_ADMIN_ROLE"), deployer);

        vm.stopBroadcast();

        // Create output directory and path
        string memory root = vm.projectRoot();
        if (!vm.exists(string.concat(root, "/script/outputs"))) {
            vm.createDir(string.concat(root, "/script/outputs"), true);
        }
        string memory path = string.concat(root, "/script/outputs/ReliquaryContracts.json");

        // Write deployment data to JSON
        writeJsonData(
            address(reliquary),
            linearPlateauCurve,
            nftDescriptor,
            parentRewarder,
            address(rewarder),
            path
        );

        console2.log("Reliquary deployed at: ", address(reliquary));
        console2.log("LinearPlateauCurve deployed at: ", linearPlateauCurve);
        console2.log("NftDescriptor deployed at: ", nftDescriptor);
        console2.log("ParentRewarder deployed at: ", parentRewarder);
        console2.log("Rewarder deployed at: ", address(rewarder));

        return (
            address(reliquary), linearPlateauCurve, nftDescriptor, parentRewarder, address(rewarder)
        );
    }
}
