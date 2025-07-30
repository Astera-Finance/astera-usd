// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StablePoolFactory} from
    "lib/balancer-v3-monorepo/pkg/pool-stable/contracts/StablePoolFactory.sol";
import {
    TokenConfig,
    TokenType,
    PoolRoleAccounts,
    LiquidityManagement,
    AddLiquidityKind,
    RemoveLiquidityKind,
    AddLiquidityParams,
    RemoveLiquidityParams
} from "lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/VaultTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "test/helpers/Sort.sol";
import {IRateProvider} from
    "lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import {Oracle} from "lib/astera/contracts/protocol/core/Oracle.sol";
import {ILendingPool} from "lib/astera/contracts/interfaces/ILendingPool.sol";
import {ILendingPoolAddressesProvider} from
    "lib/astera/contracts/interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPoolConfigurator} from
    "lib/astera/contracts/interfaces/ILendingPoolConfigurator.sol";
import {AsUsdAToken} from "contracts/facilitators/astera/token/AsUsdAToken.sol";
import {AsUsdVariableDebtToken} from
    "contracts/facilitators/astera/token/AsUsdVariableDebtToken.sol";
import {DataTypes} from "lib/astera/contracts/protocol/libraries/types/DataTypes.sol";
import {DeploymentConstants} from "./DeploymentConstants.sol";

import {console2} from "forge-std/console2.sol";

struct ExtContractsForConfiguration {
    address treasury;
    address rewarder;
    address oracle;
    address lendingPoolConfigurator;
    address lendingPoolAddressesProvider;
    address aTokenImpl;
    address variableDebtTokenImpl;
    address interestStrat;
}

struct PoolReserversConfig {
    bool borrowingEnabled;
    uint256 reserveFactor;
    bool reserveType;
}

contract DeploymentFixtures is Sort, DeploymentConstants {
    function createStablePool(
        IERC20[] memory assets,
        uint256 amplificationParameter,
        address stablePoolFactory
    ) public returns (address) {
        // sort tokens
        IERC20[] memory tokens = new IERC20[](assets.length);

        tokens = sort(assets);
        TokenConfig[] memory tokenConfigs = new TokenConfig[](assets.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenConfigs[i] = TokenConfig({
                token: tokens[i],
                tokenType: TokenType.STANDARD,
                rateProvider: IRateProvider(address(0)),
                paysYieldFees: false
            });
        }
        PoolRoleAccounts memory roleAccounts;
        roleAccounts.pauseManager = address(0);
        roleAccounts.swapFeeManager = address(0);
        roleAccounts.poolCreator = address(0);

        address stablePool = address(
            StablePoolFactory(address(stablePoolFactory)).create(
                "Astera-USD-Pool",
                "CUP",
                tokenConfigs,
                amplificationParameter, // test only
                roleAccounts,
                1e12, // 0.001% (in WAD)
                address(0),
                false,
                false,
                bytes32(keccak256(abi.encode(tokenConfigs, bytes("Astera-USD-Pool"), bytes("CUP"))))
            )
        );

        return (address(stablePool));
    }

    function fixture_configureAsUsd(
        ExtContractsForConfiguration memory _extContractsForConfiguration,
        PoolReserversConfig memory _poolReserversConfig,
        address _asUsd,
        address _reliquaryAsUsdRewarder,
        address _asUsdAggregator,
        uint256 _reliquaryAllocation,
        uint256 _oracleTimeout,
        address _deployer,
        address _keeper
    ) public {
        {
            address[] memory asset = new address[](1);
            address[] memory aggregator = new address[](1);
            uint256[] memory timeout = new uint256[](1);

            asset[0] = _asUsd;
            aggregator[0] = _asUsdAggregator;
            timeout[0] = _oracleTimeout;

            // vm.prank(deployer);
            Oracle(_extContractsForConfiguration.oracle).setAssetSources(asset, aggregator, timeout);
        }

        fixture_configureReservesAsUsd(
            _extContractsForConfiguration, _poolReserversConfig, _asUsd, _deployer
        );
        address lendingPool = ILendingPoolAddressesProvider(
            _extContractsForConfiguration.lendingPoolAddressesProvider
        ).getLendingPool();
        DataTypes.ReserveData memory reserveDataTemp =
            ILendingPool(lendingPool).getReserveData(_asUsd, _poolReserversConfig.reserveType);
        // vm.startPrank(deployer);
        AsUsdAToken(reserveDataTemp.aTokenAddress).setVariableDebtToken(
            reserveDataTemp.variableDebtTokenAddress
        );
        ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator).setTreasury(
            address(_asUsd), _poolReserversConfig.reserveType, constantsTreasury
        );
        AsUsdAToken(reserveDataTemp.aTokenAddress).setReliquaryInfo(
            _reliquaryAsUsdRewarder, _reliquaryAllocation
        );
        AsUsdAToken(reserveDataTemp.aTokenAddress).setKeeper(_keeper);
        DataTypes.ReserveData memory reserve =
            ILendingPool(lendingPool).getReserveData(_asUsd, _poolReserversConfig.reserveType);

        AsUsdVariableDebtToken(reserveDataTemp.variableDebtTokenAddress).setAToken(
            reserveDataTemp.aTokenAddress
        );
        // vm.stopPrank();
    }

    function fixture_configureReservesAsUsd(
        ExtContractsForConfiguration memory _extContractsForConfiguration,
        PoolReserversConfig memory poolReserversConfig,
        address _asUsd,
        address _owner
    ) public {
        ILendingPoolConfigurator.InitReserveInput[] memory initInputParams =
            new ILendingPoolConfigurator.InitReserveInput[](1);

        address lendingPool = ILendingPoolAddressesProvider(
            _extContractsForConfiguration.lendingPoolAddressesProvider
        ).getLendingPool();
        if (ILendingPool(lendingPool).paused()) {
            ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator)
                .setPoolPause(false);
        }

        string memory tmpSymbol = ERC20(_asUsd).symbol();

        initInputParams[0] = ILendingPoolConfigurator.InitReserveInput({
            aTokenImpl: _extContractsForConfiguration.aTokenImpl,
            variableDebtTokenImpl: _extContractsForConfiguration.variableDebtTokenImpl,
            underlyingAssetDecimals: ERC20(_asUsd).decimals(),
            interestRateStrategyAddress: _extContractsForConfiguration.interestStrat,
            underlyingAsset: _asUsd,
            reserveType: poolReserversConfig.reserveType,
            treasury: _extContractsForConfiguration.treasury,
            incentivesController: _extContractsForConfiguration.rewarder,
            underlyingAssetName: tmpSymbol,
            aTokenName: string.concat("Astera ", tmpSymbol),
            aTokenSymbol: string.concat("as-", tmpSymbol),
            variableDebtTokenName: string.concat("Astera variable debt bearing ", tmpSymbol),
            variableDebtTokenSymbol: string.concat("asDebt-", tmpSymbol),
            params: "0x10"
        });

        ILendingPoolConfigurator(address(_extContractsForConfiguration.lendingPoolConfigurator))
            .batchInitReserve(initInputParams);

        // @audit Do wee need inital borrow to prevent any index inflation ? or index inflation will not exist for asUSD ?

        ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator)
            .enableBorrowingOnReserve(_asUsd, poolReserversConfig.reserveType);

        if (!poolReserversConfig.borrowingEnabled) {
            ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator)
                .disableBorrowingOnReserve(_asUsd, poolReserversConfig.reserveType);
        }
        ILendingPool lp = ILendingPool(
            ILendingPoolAddressesProvider(
                _extContractsForConfiguration.lendingPoolAddressesProvider
            ).getLendingPool()
        );
        DataTypes.ReserveData memory reserveDataTemp =
            lp.getReserveData(_asUsd, poolReserversConfig.reserveType);
        console2.log(
            "reserveDataTemp.variableDebtTokenAddress: ", reserveDataTemp.variableDebtTokenAddress
        );

        ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator)
            .setAsteraReserveFactor(
            _asUsd, poolReserversConfig.reserveType, poolReserversConfig.reserveFactor
        );
        ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator)
            .enableFlashloan(_asUsd, poolReserversConfig.reserveType);

        if (!ILendingPool(lendingPool).paused()) {
            ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator)
                .setPoolPause(true);
        }
    }
}
