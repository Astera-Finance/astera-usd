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
import {Oracle} from "lib/Cod3x-Lend/contracts/protocol/core/Oracle.sol";
import {ILendingPool} from "lib/Cod3x-Lend/contracts/interfaces/ILendingPool.sol";
import {ILendingPoolAddressesProvider} from
    "lib/Cod3x-Lend/contracts/interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPoolConfigurator} from
    "lib/Cod3x-Lend/contracts/interfaces/ILendingPoolConfigurator.sol";
import {CdxUsdAToken} from "contracts/facilitators/cod3x_lend/token/CdxUsdAToken.sol";
import {CdxUsdVariableDebtToken} from
    "contracts/facilitators/cod3x_lend/token/CdxUsdVariableDebtToken.sol";
import {DataTypes} from "lib/Cod3x-Lend/contracts/protocol/libraries/types/DataTypes.sol";
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
                "Cod3x-USD-Pool",
                "CUP",
                tokenConfigs,
                amplificationParameter, // test only
                roleAccounts,
                1e12, // 0.001% (in WAD)
                address(0),
                false,
                false,
                bytes32(keccak256(abi.encode(tokenConfigs, bytes("Cod3x-USD-Pool"), bytes("CUP"))))
            )
        );

        return (address(stablePool));
    }

    function fixture_configureCdxUsd(
        ExtContractsForConfiguration memory _extContractsForConfiguration,
        PoolReserversConfig memory _poolReserversConfig,
        address _cdxUsd,
        address _reliquaryCdxUsdRewarder,
        address _cdxUsdAggregator,
        uint256 _reliquaryAllocation,
        uint256 _oracleTimeout,
        address _deployer,
        address _keeper
    ) public {
        {
            address[] memory asset = new address[](1);
            address[] memory aggregator = new address[](1);
            uint256[] memory timeout = new uint256[](1);

            asset[0] = _cdxUsd;
            aggregator[0] = _cdxUsdAggregator;
            timeout[0] = _oracleTimeout;

            // vm.prank(deployer);
            Oracle(_extContractsForConfiguration.oracle).setAssetSources(asset, aggregator, timeout);
        }

        fixture_configureReservesCdxUsd(
            _extContractsForConfiguration, _poolReserversConfig, _cdxUsd, _deployer
        );
        address lendingPool = ILendingPoolAddressesProvider(
            _extContractsForConfiguration.lendingPoolAddressesProvider
        ).getLendingPool();
        DataTypes.ReserveData memory reserveDataTemp =
            ILendingPool(lendingPool).getReserveData(_cdxUsd, _poolReserversConfig.reserveType);
        // vm.startPrank(deployer);
        CdxUsdAToken(reserveDataTemp.aTokenAddress).setVariableDebtToken(
            reserveDataTemp.variableDebtTokenAddress
        );
        ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator).setTreasury(
            address(_cdxUsd), _poolReserversConfig.reserveType, constantsTreasury
        );
        CdxUsdAToken(reserveDataTemp.aTokenAddress).setReliquaryInfo(
            _reliquaryCdxUsdRewarder, _reliquaryAllocation
        );
        CdxUsdAToken(reserveDataTemp.aTokenAddress).setKeeper(_keeper);
        DataTypes.ReserveData memory reserve =
            ILendingPool(lendingPool).getReserveData(_cdxUsd, _poolReserversConfig.reserveType);

        CdxUsdVariableDebtToken(reserveDataTemp.variableDebtTokenAddress).setAToken(
            reserveDataTemp.aTokenAddress
        );
        // vm.stopPrank();
    }

    function fixture_configureReservesCdxUsd(
        ExtContractsForConfiguration memory _extContractsForConfiguration,
        PoolReserversConfig memory poolReserversConfig,
        address _cdxUsd,
        address _owner
    ) public {
        ILendingPoolConfigurator.InitReserveInput[] memory initInputParams =
            new ILendingPoolConfigurator.InitReserveInput[](1);

        string memory tmpSymbol = ERC20(_cdxUsd).symbol();

        initInputParams[0] = ILendingPoolConfigurator.InitReserveInput({
            aTokenImpl: _extContractsForConfiguration.aTokenImpl,
            variableDebtTokenImpl: _extContractsForConfiguration.variableDebtTokenImpl,
            underlyingAssetDecimals: ERC20(_cdxUsd).decimals(),
            interestRateStrategyAddress: _extContractsForConfiguration.interestStrat,
            underlyingAsset: _cdxUsd,
            reserveType: poolReserversConfig.reserveType,
            treasury: _extContractsForConfiguration.treasury,
            incentivesController: _extContractsForConfiguration.rewarder,
            underlyingAssetName: tmpSymbol,
            aTokenName: string.concat("Cod3x Lend ", tmpSymbol),
            aTokenSymbol: string.concat("cl", tmpSymbol),
            variableDebtTokenName: string.concat("Cod3x Lend variable debt bearing ", tmpSymbol),
            variableDebtTokenSymbol: string.concat("variableDebt", tmpSymbol),
            params: "0x10"
        });

        // vm.startPrank(_owner);
        ILendingPoolConfigurator(address(_extContractsForConfiguration.lendingPoolConfigurator))
            .batchInitReserve(initInputParams);

        // uint256 tokenPrice = _extContractsForConfiguration.oracle.getAssetPrice(_cdxUsd);
        // uint256 tokenAmount = usdBootstrapAmount * contracts.oracle.BASE_CURRENCY_UNIT()
        //     * 10 ** IERC20Detailed(_cdxUsd).decimals() / tokenPrice;

        // console2.log(
        //     "Bootstrap amount: %s %s for price: %s",
        //     tokenAmount,
        //     IERC20Detailed(_cdxUsd).symbol(),
        //     tokenPrice
        // );
        ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator)
            .enableBorrowingOnReserve(_cdxUsd, poolReserversConfig.reserveType);
        // _contracts.lendingPool.borrow(
        //     _cdxUsd,
        //     reserveConfig.reserveType,
        //     tokenAmount / 2,
        //     _contracts.lendingPoolAddressesProvider.getPoolAdmin()
        // );
        // reserveData = _contracts.lendingPool.getReserveData(_cdxUsd, reserveConfig.reserveType);
        // require(
        //     IERC20Detailed(reserveData.variableDebtTokenAddress).totalSupply() == tokenAmount / 2,
        //     "TotalSupply of debt not equal to borrowed amount!"
        // );

        if (!poolReserversConfig.borrowingEnabled) {
            ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator)
                .disableBorrowingOnReserve(_cdxUsd, poolReserversConfig.reserveType);
        }
        ILendingPool lp = ILendingPool(
            ILendingPoolAddressesProvider(
                _extContractsForConfiguration.lendingPoolAddressesProvider
            ).getLendingPool()
        );
        DataTypes.ReserveData memory reserveDataTemp =
            lp.getReserveData(_cdxUsd, poolReserversConfig.reserveType);
        console2.log(
            "reserveDataTemp.variableDebtTokenAddress: ", reserveDataTemp.variableDebtTokenAddress
        );

        ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator)
            .setCod3xReserveFactor(
            _cdxUsd, poolReserversConfig.reserveType, poolReserversConfig.reserveFactor
        );
        ILendingPoolConfigurator(_extContractsForConfiguration.lendingPoolConfigurator)
            .enableFlashloan(_cdxUsd, poolReserversConfig.reserveType);
        // vm.stopPrank();
    }
}
