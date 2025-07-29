// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {
    DeploymentFixtures,
    ExtContractsForConfiguration,
    PoolReserversConfig,
    ILendingPool,
    ILendingPoolAddressesProvider,
    AsUsdAToken,
    AsUsdVariableDebtToken,
    DataTypes
} from "./DeploymentFixtures.s.sol";
import {AsUsdOracle} from "contracts/facilitators/astera/oracle/AsUSDOracle.sol";
import {MockV3Aggregator} from "test/helpers/mocks/MockV3Aggregator.sol";
import {AsUsdIInterestRateStrategy} from
    "contracts/facilitators/astera/interest_strategy/AsUsdIInterestRateStrategy.sol";
import {AsUSD} from "contracts/tokens/AsUSD.sol";

import {console2} from "forge-std/console2.sol";

contract InitUsdInLending is Script, DeploymentFixtures {
    struct DeployedContracts {
        AsUsdIInterestRateStrategy asUsdInterestRateStrategy;
        address asUsdAToken;
        address asUsdVariableDebtToken;
        address asUsdAggregator;
        MockV3Aggregator counterAssetPriceFeed;
    }

    uint256 constant RELIQUARY_ALLOCATION = 8000; /* 80% */
    uint256 constant ORACLE_TIMEOUT = 86400; // 1 day
    uint256 constant PEG_MARGIN = 1e26; // 10%
    uint8 constant PRICE_FEED_DECIMALS = 8;
    uint128 constant BUCKET_CAPACITY = 0; // 1000000e18;
    int256 constant MIN_CONTROLLER_ERROR = 1e25;
    int256 constant INITIAL_ERR_I_VALUE = 1e25;
    uint256 constant KI = 13e19;

    address STABLE_POOL = address(2); // Fill with deployed contract
    address RELIQUARY = address(3); // Fill with deployed contract

    /**
     * @dev use this function ONLY for DeployAll.s.sol
     */
    function initInterestStratAndReliquary(address _stablePool, address _reliquary) public {
        STABLE_POOL = _stablePool;
        RELIQUARY = _reliquary;
    }

    function writeJsonData(
        DeployedContracts memory deployedContracts,
        address actualAToken,
        address actualVariableDebtToken,
        string memory path
    ) internal {
        // Serialize only the contracts deployed in this script
        vm.serializeAddress(
            "asUsdLendingInit",
            "asUsdInterestRateStrategy",
            address(deployedContracts.asUsdInterestRateStrategy)
        );
        vm.serializeAddress("asUsdLendingInit", "asUsdATokenImpl", deployedContracts.asUsdAToken);
        vm.serializeAddress(
            "asUsdLendingInit",
            "asUsdVariableDebtTokenImpl",
            deployedContracts.asUsdVariableDebtToken
        );
        vm.serializeAddress(
            "asUsdLendingInit", "asUsdAggregator", deployedContracts.asUsdAggregator
        );
        vm.serializeAddress(
            "asUsdLendingInit",
            "counterAssetPriceFeed",
            address(deployedContracts.counterAssetPriceFeed)
        );

        // Include actual deployed tokens from lending pool (configured but not deployed here)
        vm.serializeAddress("asUsdLendingInit", "asUsdAToken", actualAToken);
        string memory output = vm.serializeAddress(
            "asUsdLendingInit", "asUsdVariableDebtToken", actualVariableDebtToken
        );

        // Write to file
        vm.writeJson(output, path);
        console2.log("ASUSD LENDING INITIALIZATION COMPLETE (check addresses at %s)", path);
    }

    function run() public {
        DeployedContracts memory deployedContracts;
        /// ========= Init asteraUsd on Astera =========
        console2.log("====== Init asteraUsd on Astera ======");
        initializeConstants();

        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        console2.log("Deployer address: ", deployer);

        ILendingPool lendingPool = ILendingPool(
            ILendingPoolAddressesProvider(extContracts.lendingPoolAddressesProvider).getLendingPool(
            )
        );

        console2.log("====== Interest strat Deploy ======");
        {
            deployedContracts.asUsdInterestRateStrategy = new AsUsdIInterestRateStrategy(
                extContracts.lendingPoolAddressesProvider,
                address(asUsd),
                false, // Not used
                balancerContracts.balVault, // balancerVault,
                STABLE_POOL,
                MIN_CONTROLLER_ERROR,
                INITIAL_ERR_I_VALUE, // starts at 2% interest rate
                KI
            );
        }

        console2.log("========= aTokens Deploy =========");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        deployedContracts.asUsdAToken = address(new AsUsdAToken());
        deployedContracts.asUsdVariableDebtToken = address(new AsUsdVariableDebtToken());

        console2.log("========= Oracle Deploy =========");
        deployedContracts.asUsdAggregator = address(new AsUsdOracle());
        deployedContracts.counterAssetPriceFeed =
            new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(1 * 10 ** PRICE_FEED_DECIMALS));
        deployedContracts.asUsdInterestRateStrategy.setOracleValues(
            address(deployedContracts.counterAssetPriceFeed), PEG_MARGIN, ORACLE_TIMEOUT
        );

        {
            ExtContractsForConfiguration memory extContractsForConfiguration =
            ExtContractsForConfiguration({
                treasury: multisignAdmin,
                rewarder: extContracts.rewarder,
                oracle: extContracts.oracle,
                lendingPoolConfigurator: extContracts.lendingPoolConfigurator,
                lendingPoolAddressesProvider: extContracts.lendingPoolAddressesProvider,
                aTokenImpl: deployedContracts.asUsdAToken,
                variableDebtTokenImpl: deployedContracts.asUsdVariableDebtToken,
                interestStrat: address(deployedContracts.asUsdInterestRateStrategy)
            });
            console2.log("=== asUsd configuration ===");
            PoolReserversConfig memory poolReserversConfig =
                PoolReserversConfig({borrowingEnabled: true, reserveFactor: 0, reserveType: false});
            fixture_configureAsUsd(
                extContractsForConfiguration,
                poolReserversConfig,
                address(asUsd),
                RELIQUARY,
                deployedContracts.asUsdAggregator,
                RELIQUARY_ALLOCATION,
                ORACLE_TIMEOUT,
                deployer,
                keeper
            );

            console2.log("=== Adding Facilitator ===");
            DataTypes.ReserveData memory reserveData =
                lendingPool.getReserveData(asUsd, poolReserversConfig.reserveType);
            if (BUCKET_CAPACITY > 0) {
                AsUSD(asUsd).addFacilitator(reserveData.aTokenAddress, "aToken", BUCKET_CAPACITY);
            }

            vm.stopBroadcast();

            // Get actual deployed aToken and debt token addresses
            address actualAToken = lendingPool.getReserveData(asUsd, false).aTokenAddress;
            address actualVariableDebtToken =
                lendingPool.getReserveData(asUsd, false).variableDebtTokenAddress;

            // Create output directory and path
            string memory root = vm.projectRoot();
            if (!vm.exists(string.concat(root, "/script/outputs"))) {
                vm.createDir(string.concat(root, "/script/outputs"), true);
            }
            string memory path = string.concat(root, "/script/outputs/InitUsdInLending.s.json");

            // Write deployment data to JSON
            writeJsonData(deployedContracts, actualAToken, actualVariableDebtToken, path);

            console2.log(
                "Interest start deployed at: ", address(deployedContracts.asUsdInterestRateStrategy)
            );
            console2.log("asUsdAToken deployed at: ", deployedContracts.asUsdAToken);
            console2.log(
                "asUsdVariableDebtToken deployed at: ", deployedContracts.asUsdVariableDebtToken
            );
            console2.log("asUsdAggregator deployed at: ", deployedContracts.asUsdAggregator);
            console2.log(
                "counterAssetPriceFeed deployed at: ",
                address(deployedContracts.counterAssetPriceFeed)
            );

            console2.log("asUsdAToken deployed at: ", actualAToken);
            console2.log("asUsdVariableDebtToken deployed at: ", actualVariableDebtToken);
        }
    }
}
