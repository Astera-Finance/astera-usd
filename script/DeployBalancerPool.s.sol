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

    function run() public returns (address) {
        // using https://pool-creator.balancer.fi/v3 is safer.
        console2.log("====== Balancer Stable Pool Deployment ======");
        initializeConstants();
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console2.log("Deployer address: ", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
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

        console2.log("Stable pool deployed at: ", stablePool);

        return stablePool;
    }
}
