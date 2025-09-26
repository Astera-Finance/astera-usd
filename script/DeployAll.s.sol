pragma solidity ^0.8.22;

import {DeployBalancerPool} from "./DeployBalancerPool.s.sol";
import {DeployReliquary} from "./DeployReliquary.s.sol";
import {DeployVaultStrategy} from "./DeployVaultStrategy.s.sol";
import {InitUsdInLending} from "./InitUsdInLending.s.sol";
// import {DeployBalancerPool} from "./DeployBalancerPool.s.sol";

import {console2} from "forge-std/console2.sol";

contract DeployAll {
    function run() public {
        /* Deploy Balancer Pool */
        DeployBalancerPool deployBalancerPool = new DeployBalancerPool();
        address stablePool = deployBalancerPool.run();
        /* Deploy Reliquary */
        DeployReliquary deployReliquary = new DeployReliquary();
        deployReliquary.initStablePool(stablePool);
        (
            address reliquary,
            address linearPlateauCurve,
            address nftDescriptor,
            address parentRewarder,
            address rewarder
        ) = deployReliquary.run();
        /* Deploy Vault Strategy */
        DeployVaultStrategy deployVaultStrategy = new DeployVaultStrategy();
        deployVaultStrategy.initStablePoolAndReliquary(stablePool, reliquary);
        (address balancerV3Router, address asteraVault, address strategy) =
            deployVaultStrategy.run();

        console2.log("Strategy: ", strategy);
        /* Init USD In Lending */
        InitUsdInLending initUsdInLending = new InitUsdInLending();
        initUsdInLending.initInterestStratAndReliquary(stablePool, reliquary);
        initUsdInLending.run();
    }
}
