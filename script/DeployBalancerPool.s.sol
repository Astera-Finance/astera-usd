// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {DeploymentFixtures, IERC20} from "./DeploymentFixtures.s.sol";
import {TRouter} from "test/helpers/TRouter.sol";
import {IVaultExplorer} from
    "lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultExplorer.sol";

import {console2} from "forge-std/console2.sol";

contract DeployBalancerPool is Script, DeploymentFixtures {
    uint256 constant AMPLIFICATION_PARAM = 2500;

    function writeJsonData(address stablePool, address tRouter, string memory path) internal {
        // Serialize the main contracts
        vm.serializeAddress("balancerDeployment", "stablePool", stablePool);
        vm.serializeAddress("balancerDeployment", "tRouter", tRouter);

        // Get and serialize pool tokens
        IERC20[] memory poolTokens =
            IVaultExplorer(balancerContracts.balVault).getPoolTokens(stablePool);
        address[] memory poolTokenAddresses = new address[](poolTokens.length);
        for (uint256 i = 0; i < poolTokens.length; i++) {
            poolTokenAddresses[i] = address(poolTokens[i]);
        }
        vm.serializeAddress("balancerDeployment", "poolTokens", poolTokenAddresses);

        // Serialize other relevant addresses
        vm.serializeAddress("balancerDeployment", "balVault", balancerContracts.balVault);
        vm.serializeAddress(
            "balancerDeployment", "stablePoolFactory", balancerContracts.stablePoolFactory
        );
        string memory output = vm.serializeAddress("balancerDeployment", "asUsd", asUsd);

        // Write to file
        vm.writeJson(output, path);
        console2.log("BALANCER POOL DEPLOYED (check addresses at %s)", path);
    }

    function run() public returns (address) {
        // using https://pool-creator.balancer.fi/v3 is safer.
        console2.log("====== Balancer Stable Pool Deployment ======");
        initializeConstants();
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console2.log("Deployer address: ", deployer);

        vm.startBroadcast(pk);
        TRouter tRouter = new TRouter(balancerContracts.balVault); // Do we want to deploy this helper or actions shall be done off chain ?
        uint256 initialAsAmt = 10e18;
        uint256 initialCounterAssetAmt = 10e6;
        IERC20[] memory assets = new IERC20[](2);
        assets[0] = IERC20(asUsd);
        assets[1] = IERC20(usdcAddress);
        assets = sort(assets);
        address stablePool =
            createStablePool(assets, AMPLIFICATION_PARAM, balancerContracts.stablePoolFactory);
        IERC20[] memory setupPoolTokens =
            IVaultExplorer(balancerContracts.balVault).getPoolTokens(stablePool);
        uint256 indexAsUsdTemp;
        uint256 indexCounterAssetTemp;

        for (uint256 i = 0; i < setupPoolTokens.length; i++) {
            console2.log("setupPoolTokens[i]: ", address(setupPoolTokens[i]));
            if (setupPoolTokens[i] == IERC20(asUsd)) indexAsUsdTemp = i;
            if (setupPoolTokens[i] == IERC20(usdcAddress)) indexCounterAssetTemp = i;
        }

        uint256[] memory amountsToAdd = new uint256[](setupPoolTokens.length);
        amountsToAdd[indexAsUsdTemp] = initialAsAmt;
        amountsToAdd[indexCounterAssetTemp] = initialCounterAssetAmt;

        IERC20(asUsd).approve(address(tRouter), type(uint256).max);
        IERC20(usdcAddress).approve(address(tRouter), type(uint256).max);
        console2.log("Sender's balance of asUSD: ", IERC20(asUsd).balanceOf(deployer));
        console2.log("Sender's balance of USDC: ", IERC20(usdcAddress).balanceOf(deployer));
        tRouter.initialize(stablePool, assets, amountsToAdd);

        IERC20(stablePool).transfer(constantsTreasury, 1);
        vm.stopBroadcast();

        // Determine output path based on network
        string memory root = vm.projectRoot();
        string memory path;

        console2.log("Mainnet Deployment");
        if (!vm.exists(string.concat(root, "/script/outputs"))) {
            vm.createDir(string.concat(root, "/script/outputs"), true);
        }
        path = string.concat(root, "/script/outputs/BalancerPoolContracts.json");

        // Write deployment data to JSON
        writeJsonData(stablePool, address(tRouter), path);

        console2.log("Stable pool deployed at: ", stablePool);

        return stablePool;
    }
}
