// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {DeploymentConstants} from "./DeploymentConstants.sol";
import {FeeControllerMock} from "./FeeControllerMock.sol";
import {BalancerV3Router} from
    "contracts/staking_module/vault_strategy/libraries/BalancerV3Router.sol";
import {IFeeController} from "lib/astera-vault/src/interfaces/IFeeController.sol";
import {ReaperVaultV2} from "lib/astera-vault/src/ReaperVaultV2.sol";
import {SasUsdVaultStrategy} from "contracts/staking_module/vault_strategy/SasUsdVaultStrategy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Reliquary} from "contracts/staking_module/reliquary/Reliquary.sol";

import {console2} from "forge-std/console2.sol";

contract DeployVaultStrategy is Script, DeploymentConstants {
    string constant VAULT_NAME = "Staked Astera USD";
    string constant VAULT_SYMBOL = "sasUsd";
    uint256 constant RELIC_ID = 1;

    address constant STABLE_POOL = address(1); // fill with deployed stable pool
    address constant RELIQUARY = address(2);

    function run() public returns (address, address, address) {
        /// ========== sasUsd Vault Strategy Deploy ===========

        address FEE_CONTROLLER = address(new FeeControllerMock());
        {
            console2.log("====== sasUsd Vault Strategy Deployment ======");
            initializeConstants();
            uint256 pk = vm.envUint("PRIVATE_KEY");
            address deployer = vm.addr(pk);
            console2.log("Deployer address: ", deployer);

            vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
            address[] memory interactors = new address[](1); // @audit ATTENTION should be :: new address[](0)
            interactors[0] = deployer; // @audit ATTENTION remove this !!!!!
            BalancerV3Router balancerV3Router =
                new BalancerV3Router(address(balancerContracts.balVault), deployer, interactors); // @audit make sure balVault is always Balancer VaultV3.

            address[] memory ownerArr = new address[](3); // @audit (2)
            ownerArr[0] = deployer; // @audit ATTENTION keep it but to be revoked.
            ownerArr[1] = multisignAdmin;
            ownerArr[2] = multisignAdmin; // @audit ATTENTION remove this !!!!!

            address[] memory ownerArr1 = new address[](1); // @audit  remove this useless array.
            ownerArr[0] = deployer;

            IFeeController(FEE_CONTROLLER).updateManagementFeeBPS(0); // @audit you can remove this with the implementation in the gist.

            ReaperVaultV2 asteraVault = new ReaperVaultV2(
                STABLE_POOL,
                VAULT_NAME,
                VAULT_SYMBOL,
                type(uint256).max,
                0,
                constantsTreasury,
                ownerArr,
                ownerArr,
                FEE_CONTROLLER
            );

            SasUsdVaultStrategy implementation = new SasUsdVaultStrategy();
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            SasUsdVaultStrategy strategy = SasUsdVaultStrategy(address(proxy));

            Reliquary(RELIQUARY).transferFrom(deployer, address(strategy), RELIC_ID); // transfer Relic#1 to strategy.

            // @audit use this array for strategy.
            // address[] memory ownerArrStrategy = new address[](1);
            // ownerArrStrategy[0] = multisignAdmin;

            strategy.initialize(
                address(asteraVault),
                address(balancerContracts.balVault),
                address(balancerV3Router),
                ownerArr1, // @audit put ownerArrStrategy
                ownerArr, // @audit put ownerArrStrategy
                ownerArr1, // @audit create a keeper arrays with multisignAdmin, multisignGuardian and ask wetzo for the keeper address he will setup.
                address(asUsd),
                address(RELIQUARY),
                address(STABLE_POOL)
            );

            asteraVault.addStrategy(address(strategy), 0, 10_000); // 100 % invested

            //DEFAULT AMIND ROLE - balancer team shall do it // @audit you mean we should do it ? why balancer team ? we own balancerV3Router.
            address[] memory interactors2 = new address[](1);
            interactors2[0] = address(strategy);
            balancerV3Router.setInteractors(interactors2);
            vm.stopBroadcast();

            // @audit ATTENTION - GRANT multisignAdmin to DEFAULT_ADMIN_ROLE from BalancerV3Router.sol.
            // @audit ATTENTION - REVOKE msg.sender/deployer from DEFAULT_ADMIN_ROLE role!!!!!!! from BalancerV3Router.sol.

            // @audit ATTENTION - GRANT multisignAdmin to DEFAULT_ADMIN_ROLE from ReaperVaultV2.sol.
            // @audit ATTENTION - REVOKE msg.sender/deployer from DEFAULT_ADMIN_ROLE role!!!!!!! from ReaperVaultV2.sol.

            console2.log("BalancerV3Router deployed at", address(balancerV3Router));
            console2.log("AsteraVault deployed at", address(asteraVault));
            console2.log("Strategy deployed at", address(strategy));

            return (address(balancerV3Router), address(asteraVault), address(strategy));
        }
    }
}
