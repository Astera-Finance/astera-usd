// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {
    DeploymentFixtures,
    ExtContractsForConfiguration,
    PoolReserversConfig,
    ILendingPool,
    ILendingPoolAddressesProvider,
    CdxUsdAToken,
    CdxUsdVariableDebtToken,
    DataTypes
} from "./DeploymentFixtures.s.sol";
import {CdxUsdOracle} from "contracts/facilitators/cod3x_lend/oracle/CdxUSDOracle.sol";
import {MockV3Aggregator} from "test/helpers/mocks/MockV3Aggregator.sol";
import {CdxUsdIInterestRateStrategy} from
    "contracts/facilitators/cod3x_lend/interest_strategy/CdxUsdIInterestRateStrategy.sol";
import {CdxUSD} from "contracts/tokens/CdxUSD.sol";

import {console2} from "forge-std/console2.sol";

contract InitUsdInLending is Script, DeploymentFixtures {
    uint256 constant RELIQUARY_ALLOCATION = 8000; /* 80% */
    uint256 constant ORACLE_TIMEOUT = 86400; // 1 day
    uint256 constant PEG_MARGIN = 1e26; // 10%
    uint8 constant PRICE_FEED_DECIMALS = 8;

    address constant CDX_USD_INTEREST_STRATEGY = address(2); // Fill with deployed contract
    address constant RELIQUARY = address(3); // Fill with deployed contract

    function run() public {
        /// ========= Init cod3xUsd on cod3x lend =========
        console2.log("====== Init cod3xUsd on cod3x lend ======");
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
        address cdxUsdAToken = address(new CdxUsdAToken());
        address cdxUsdVariableDebtToken = address(new CdxUsdVariableDebtToken());

        console2.log("========= Oracle Deploy =========");
        address cdxUsdAggregator = address(new CdxUsdOracle());
        MockV3Aggregator counterAssetPriceFeed =
            new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(1 * 10 ** PRICE_FEED_DECIMALS));
        CdxUsdIInterestRateStrategy(CDX_USD_INTEREST_STRATEGY).setOracleValues(
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
                aTokenImpl: cdxUsdAToken,
                variableDebtTokenImpl: cdxUsdVariableDebtToken,
                interestStrat: CDX_USD_INTEREST_STRATEGY
            });
            console2.log("=== cdxUsd configuration ===");
            PoolReserversConfig memory poolReserversConfig =
                PoolReserversConfig({borrowingEnabled: true, reserveFactor: 0, reserveType: false});
            fixture_configureCdxUsd( // @audit plz avoid dependencies to tests/. create a "deployement version" of fixture_configureCdxUsd. that perfectly respect the "LendingPool Configuration Checklist."
                extContractsForConfiguration,
                poolReserversConfig,
                address(cdxUsd),
                RELIQUARY,
                cdxUsdAggregator,
                RELIQUARY_ALLOCATION,
                ORACLE_TIMEOUT,
                deployer,
                keeper
            );
            // fixture_configureReservesCdxUsd(
            //     extContractsForConfiguration, poolReserversConfig, cdxUsd, deployer
            // );

            /// CdxUsdAToken settings
            // contractsToDeploy.cdxUsdAToken.setVariableDebtToken(
            //     address(contractsToDeploy.cdxUsdVariableDebtToken)
            // );
            // ILendingPoolConfigurator(extContracts.lendingPoolConfigurator).setTreasury(
            //     address(cdxUsd), poolReserversConfig.reserveType, constantsTreasury
            // );
            // contractsToDeploy.cdxUsdAToken.setReliquaryInfo(
            //     address(contractsToDeploy.reliquary), RELIQUARY_ALLOCATION
            // );
            // contractsToDeploy.cdxUsdAToken.setKeeper(address(this));

            // /// CdxUsdVariableDebtToken settings
            // contractsToDeploy.cdxUsdVariableDebtToken.setAToken(
            //     address(contractsToDeploy.cdxUsdAToken)
            // );
            console2.log("=== Adding Facilitator ===");
            DataTypes.ReserveData memory reserveData =
                lendingPool.getReserveData(cdxUsd, poolReserversConfig.reserveType);
            // vm.prank(CdxUSD(cdxUsd).owner());
            CdxUSD(cdxUsd).addFacilitator(reserveData.aTokenAddress, "aToken", 100e18); // @audit define a default capacity in a configuration file. instead of 100e18 + this should be 100000e18 or 1000000e18 at launch at least.
            vm.stopBroadcast();
        }
    }
}
