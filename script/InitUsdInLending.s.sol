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
    uint128 constant BUCKET_CAPACITY = 1000000e18;
    int256 constant MIN_CONTROLLER_ERROR = 1e25; // @audit put this in a configuration file.
    int256 constant INITIAL_ERR_I_VALUE = 1e25; // @audit put this in a configuration file.
    uint256 constant KI = 13e19; // @audit put this in a configuration file.

    address STABLE_POOL = address(2); // Fill with deployed contract
    address RELIQUARY = address(3); // Fill with deployed contract

    /**
     * @dev use this function ONLY for DeployAll.s.sol
     */
    function initInterestStratAndReliquary(address _stablePool, address _reliquary) public {
        STABLE_POOL = _stablePool;
        RELIQUARY = _reliquary;
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
            fixture_configureAsUsd( // @audit plz avoid dependencies to tests/. create a "deployement version" of fixture_configureAsUsd. that perfectly respect the "LendingPool Configuration Checklist."
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
            // fixture_configureReservesAsUsd(
            //     extContractsForConfiguration, poolReserversConfig, asUsd, deployer
            // );

            /// AsUsdAToken settings
            // contractsToDeploy.asUsdAToken.setVariableDebtToken(
            //     address(contractsToDeploy.asUsdVariableDebtToken)
            // );
            // ILendingPoolConfigurator(extContracts.lendingPoolConfigurator).setTreasury(
            //     address(asUsd), poolReserversConfig.reserveType, constantsTreasury
            // );
            // contractsToDeploy.asUsdAToken.setReliquaryInfo(
            //     address(contractsToDeploy.reliquary), RELIQUARY_ALLOCATION
            // );
            // contractsToDeploy.asUsdAToken.setKeeper(address(this));

            // /// AsUsdVariableDebtToken settings
            // contractsToDeploy.asUsdVariableDebtToken.setAToken(
            //     address(contractsToDeploy.asUsdAToken)
            // );
            console2.log("=== Adding Facilitator ===");
            DataTypes.ReserveData memory reserveData =
                lendingPool.getReserveData(asUsd, poolReserversConfig.reserveType);
            // vm.prank(AsUSD(asUsd).owner());
            AsUSD(asUsd).addFacilitator(reserveData.aTokenAddress, "aToken", BUCKET_CAPACITY); // @audit define a default capacity in a configuration file. instead of 100e18 + this should be 100000e18 or 1000000e18 at launch at least.
            vm.stopBroadcast();

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

            console2.log(
                "asUsdAToken deployed at: ", lendingPool.getReserveData(asUsd, false).aTokenAddress
            );
            console2.log(
                "asUsdVariableDebtToken deployed at: ",
                lendingPool.getReserveData(asUsd, false).variableDebtTokenAddress
            );
        }
    }
}
