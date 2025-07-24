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
    uint256 constant RELIQUARY_ALLOCATION = 8000; /* 80% */
    uint256 constant ORACLE_TIMEOUT = 86400; // 1 day
    uint256 constant PEG_MARGIN = 1e26; // 10%
    uint8 constant PRICE_FEED_DECIMALS = 8;

    address constant AS_USD_INTEREST_STRATEGY = address(2); // Fill with deployed contract
    address constant RELIQUARY = address(3); // Fill with deployed contract

    function run() public {
        /// ========= Init asteraUsd on Astera =========
        console2.log("====== Init asteraUsd on Astera ======");
        initializeConstants();
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        console2.log("Deployer address: ", deployer);

        ILendingPool lendingPool = ILendingPool(
            ILendingPoolAddressesProvider(extContracts.lendingPoolAddressesProvider).getLendingPool(
            )
        );

        console2.log("========= aTokens Deploy =========");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address asUsdAToken = address(new AsUsdAToken());
        address asUsdVariableDebtToken = address(new AsUsdVariableDebtToken());

        console2.log("========= Oracle Deploy =========");
        address asUsdAggregator = address(new AsUsdOracle());
        MockV3Aggregator counterAssetPriceFeed =
            new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(1 * 10 ** PRICE_FEED_DECIMALS));
        AsUsdIInterestRateStrategy(AS_USD_INTEREST_STRATEGY).setOracleValues(
            address(counterAssetPriceFeed), PEG_MARGIN, ORACLE_TIMEOUT
        );

        {
            ExtContractsForConfiguration memory extContractsForConfiguration =
            ExtContractsForConfiguration({
                treasury: multisignAdmin,
                rewarder: extContracts.rewarder,
                oracle: extContracts.oracle,
                lendingPoolConfigurator: extContracts.lendingPoolConfigurator,
                lendingPoolAddressesProvider: extContracts.lendingPoolAddressesProvider,
                aTokenImpl: asUsdAToken,
                variableDebtTokenImpl: asUsdVariableDebtToken,
                interestStrat: AS_USD_INTEREST_STRATEGY
            });
            console2.log("=== asUsd configuration ===");
            PoolReserversConfig memory poolReserversConfig =
                PoolReserversConfig({borrowingEnabled: true, reserveFactor: 0, reserveType: false});
            fixture_configureAsUsd( // @audit plz avoid dependencies to tests/. create a "deployement version" of fixture_configureAsUsd. that perfectly respect the "LendingPool Configuration Checklist."
                extContractsForConfiguration,
                poolReserversConfig,
                address(asUsd),
                RELIQUARY,
                asUsdAggregator,
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
            AsUSD(asUsd).addFacilitator(reserveData.aTokenAddress, "aToken", 100e18); // @audit define a default capacity in a configuration file. instead of 100e18 + this should be 100000e18 or 1000000e18 at launch at least.
            vm.stopBroadcast();
        }
    }
}
