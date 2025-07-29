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
    uint16 constant MANAGEMENT_FEE_BPS = 0; // 0% management fee
    uint256 constant STRAT_ALLOCATION = 10000; // 100% allocation to strategy

    address[] KEEPERS = [multisignAdmin, multisignGuardian]; // Add here real keepers (ask @wetzo)!
    address STABLE_POOL = address(1); // Fill with deployed stable pool
    address RELIQUARY = address(2);

    /**
     * @dev use this function ONLY for DeployAll.s.sol
     */
    function initStablePoolAndReliquary(address _stablePool, address _reliquary) public {
        STABLE_POOL = _stablePool;
        RELIQUARY = _reliquary;
    }

    function writeJsonData(
        address balancerV3Router,
        address asteraVault,
        address strategy,
        string memory path
    ) internal {
        // Serialize main contract addresses
        vm.serializeAddress("vaultStrategyDeployment", "balancerV3Router", balancerV3Router);
        vm.serializeAddress("vaultStrategyDeployment", "asteraVault", asteraVault);
        string memory output = vm.serializeAddress("vaultStrategyDeployment", "strategy", strategy);

        // Write to file
        vm.writeJson(output, path);
        console2.log("VAULT STRATEGY DEPLOYED (check addresses at %s)", path);
    }

    function run() public returns (address, address, address) {
        /// ========== sasUsd Vault Strategy Deploy ===========

        address FEE_CONTROLLER = address(new FeeControllerMock());
        {
            console2.log("====== sasUsd Vault Strategy Deployment ======");
            initializeConstants();
            uint256 pk = vm.envUint("PRIVATE_KEY");
            address deployer = vm.addr(pk);
            console2.log("Deployer address: ", deployer);

            vm.startBroadcast(pk);
            address[] memory strategists = new address[](2);
            strategists[0] = multisignAdmin;
            strategists[1] = multisignGuardian;

            BalancerV3Router balancerV3Router =
                new BalancerV3Router(address(balancerContracts.balVault), deployer, strategists); // @audit make sure balVault is always Balancer VaultV3.

            address[] memory ownerArr = new address[](3);
            ownerArr[0] = multisignAdmin;
            ownerArr[1] = multisignAdmin;
            ownerArr[2] = multisignGuardian; // @audit ATTENTION remove this !!!!! -> we need 3 owners, otherwise it will revert in constructor of ReaperVaultV2.sol.

            ReaperVaultV2 asteraVault = new ReaperVaultV2(
                STABLE_POOL,
                VAULT_NAME,
                VAULT_SYMBOL,
                type(uint256).max,
                MANAGEMENT_FEE_BPS,
                constantsTreasury,
                strategists,
                ownerArr,
                FEE_CONTROLLER
            );

            SasUsdVaultStrategy implementation = new SasUsdVaultStrategy();
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            SasUsdVaultStrategy strategy = SasUsdVaultStrategy(address(proxy));

            Reliquary(RELIQUARY).transferFrom(deployer, address(strategy), RELIC_ID); // transfer Relic#1 to strategy.

            strategy.initialize(
                address(asteraVault),
                address(balancerContracts.balVault),
                address(balancerV3Router),
                strategists,
                ownerArr,
                KEEPERS,
                address(asUsd),
                address(RELIQUARY),
                address(STABLE_POOL)
            );

            asteraVault.addStrategy(address(strategy), 0, STRAT_ALLOCATION);

            asteraVault.grantRole(asteraVault.DEFAULT_ADMIN_ROLE(), multisignAdmin);
            asteraVault.revokeRole(asteraVault.DEFAULT_ADMIN_ROLE(), deployer);

            balancerV3Router.grantRole(balancerV3Router.DEFAULT_ADMIN_ROLE(), multisignAdmin);
            balancerV3Router.revokeRole(balancerV3Router.DEFAULT_ADMIN_ROLE(), deployer);

            vm.stopBroadcast();

            // Create output directory and path
            string memory root = vm.projectRoot();
            if (!vm.exists(string.concat(root, "/script/outputs"))) {
                vm.createDir(string.concat(root, "/script/outputs"), true);
            }
            string memory path = string.concat(root, "/script/outputs/VaultStrategyContracts.json");

            // Write deployment data to JSON
            writeJsonData(address(balancerV3Router), address(asteraVault), address(strategy), path);

            console2.log("BalancerV3Router deployed at", address(balancerV3Router));
            console2.log("AsteraVault deployed at", address(asteraVault));
            console2.log("Strategy deployed at", address(strategy));

            return (address(balancerV3Router), address(asteraVault), address(strategy));
        }
    }
}
