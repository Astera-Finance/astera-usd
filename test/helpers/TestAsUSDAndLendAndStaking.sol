// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

// Astera
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "lib/astera/contracts/dependencies/openzeppelin/contracts/ERC20.sol";
import "lib/astera/contracts/protocol/libraries/helpers/Errors.sol";
import "lib/astera/contracts/protocol/libraries/types/DataTypes.sol";
import {AToken} from "lib/astera/contracts/protocol/tokenization/ERC20/AToken.sol";
import {VariableDebtToken} from
    "lib/astera/contracts/protocol/tokenization/ERC20/VariableDebtToken.sol";

import {WadRayMath} from "lib/astera/contracts/protocol/libraries/math/WadRayMath.sol";
import {MathUtils} from "lib/astera/contracts/protocol/libraries/math/MathUtils.sol";
import {AsteraDataProvider} from "lib/astera/contracts/misc/AsteraDataProvider.sol";
// import {ReserveBorrowConfiguration} from  "lib/astera/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";

// Balancer
import "forge-std/console2.sol";

import {TestAsUSDAndLend} from "test/helpers/TestAsUSDAndLend.sol";
import {ERC20Mock} from "test/helpers/mocks/ERC20Mock.sol";

// reliquary
import "contracts/staking_module/reliquary/Reliquary.sol";
import "contracts/interfaces/IReliquary.sol";
import "contracts/staking_module/reliquary/nft_descriptors/NFTDescriptor.sol";
import "contracts/staking_module/reliquary/curves/LinearPlateauCurve.sol";
import "contracts/staking_module/reliquary/rewarders/RollingRewarder.sol";
import "contracts/staking_module/reliquary/rewarders/ParentRollingRewarder.sol";
import "contracts/interfaces/ICurves.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

// vault
import {ReaperBaseStrategyv4} from "lib/Astera-Vault/src/ReaperBaseStrategyv4.sol";
import {ReaperVaultV2} from "lib/Astera-Vault/src/ReaperVaultV2.sol";
import {SasUsdVaultStrategy} from
    "contracts/staking_module/vault_strategy/SasUsdVaultStrategy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "lib/Astera-Vault/test/vault/mock/FeeControllerMock.sol";

// AsUSD
import {AsUSD} from "contracts/tokens/AsUSD.sol";
import {AsUsdIInterestRateStrategy} from
    "contracts/facilitators/astera/interest_strategy/AsUsdIInterestRateStrategy.sol";
import {AsUsdOracle} from "contracts/facilitators/astera/oracle/AsUSDOracle.sol";
import {AsUsdAToken} from "contracts/facilitators/astera/token/AsUsdAToken.sol";
import {AsUsdVariableDebtToken} from
    "contracts/facilitators/astera/token/AsUsdVariableDebtToken.sol";
import {MockV3Aggregator} from "test/helpers/mocks/MockV3Aggregator.sol";

/// balancer V3 imports
import {BalancerV3Router} from
    "contracts/staking_module/vault_strategy/libraries/BalancerV3Router.sol";
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
import {IVault} from "lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import {Vault} from "lib/balancer-v3-monorepo/pkg/vault/contracts/Vault.sol";
import {StablePoolFactory} from
    "lib/balancer-v3-monorepo/pkg/pool-stable/contracts/StablePoolFactory.sol";
import {IRateProvider} from
    "lib/balancer-v3-monorepo/pkg/interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import {TRouter} from "./TRouter.sol";
import {IVaultExplorer} from
    "lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultExplorer.sol";

contract TestAsUSDAndLendAndStaking is TestAsUSDAndLend, ERC721Holder {
    using WadRayMath for uint256;
    // using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    // using ReserveBorrowConfiguration for DataTypes.ReserveBorrowConfigurationMap;

    bytes32 public poolId;
    address public poolAdd;
    IERC20[] public assets;
    IReliquary public reliquary;
    RollingRewarder public rewarder;
    ReaperVaultV2 public asteraVault;
    SasUsdVaultStrategy public strategy;
    IERC20 public mockRewardToken;
    BalancerV3Router public balancerV3Router;

    // Linear function config (to config)
    uint256 public slope = 100; // Increase of multiplier every second
    uint256 public minMultiplier = 365 days * 100; // Arbitrary (but should be coherent with slope)
    uint256 public plateauTimestamp = 10 days;
    uint256 private constant RELIC_ID = 1;

    uint256 public indexAsUsd;
    uint256 public indexCounterAsset;

    // AsUSD public asUsd;
    AsUsdIInterestRateStrategy public asUsdInterestRateStrategy;
    AsUsdOracle public asUsdOracle;
    AsUsdAToken public asUsdAToken;
    AsUsdVariableDebtToken public asUsdVariableDebtToken;
    MockV3Aggregator public counterAssetPriceFeed;

    function setUp() public virtual override {
        super.setUp();
        vm.selectFork(forkIdEth);

        /// ======= Balancer Pool Deploy =======
        {
            assets.push(IERC20(address(counterAsset)));
            assets.push(IERC20(address(asUsd)));

            IERC20[] memory assetsSorted = sort(assets);
            assets[0] = assetsSorted[0];
            assets[1] = assetsSorted[1];

            // balancer stable pool creation
            poolAdd = createStablePool(assets, 2500, userA);

            // join Pool
            IERC20[] memory setupPoolTokens = IVaultExplorer(vaultV3).getPoolTokens(poolAdd);

            uint256 indexAsUsdTemp;
            uint256 indexCounterAssetTemp;
            for (uint256 i = 0; i < setupPoolTokens.length; i++) {
                if (setupPoolTokens[i] == asUsd) indexAsUsdTemp = i;
                if (setupPoolTokens[i] == IERC20(address(counterAsset))) indexCounterAssetTemp = i;
            }

            uint256[] memory amountsToAdd = new uint256[](setupPoolTokens.length);
            amountsToAdd[indexAsUsdTemp] = INITIAL_ASUSD_AMT;
            amountsToAdd[indexCounterAssetTemp] = INITIAL_COUNTER_ASSET_AMT;

            vm.prank(userA);
            tRouter.initialize(poolAdd, assets, amountsToAdd);

            vm.prank(userA);
            IERC20(poolAdd).transfer(address(this), 1);

            for (uint256 i = 0; i < assets.length; i++) {
                if (assets[i] == asUsd) indexAsUsd = i;
                if (assets[i] == IERC20(address(counterAsset))) {
                    indexCounterAsset = i;
                }
            }
        }

        /// ========= Reliquary Deploy =========
        {
            mockRewardToken = IERC20(address(new ERC20Mock(18)));
            reliquary =
                new Reliquary(address(mockRewardToken), 0, "Reliquary sasUSD", "sasUSD Relic");
            address linearPlateauCurve =
                address(new LinearPlateauCurve(slope, minMultiplier, plateauTimestamp));

            address nftDescriptor = address(new NFTDescriptor(address(reliquary)));

            address parentRewarder = address(new ParentRollingRewarder());

            Reliquary(address(reliquary)).grantRole(keccak256("OPERATOR"), address(this));
            Reliquary(address(reliquary)).grantRole(keccak256("GUARDIAN"), address(this));
            Reliquary(address(reliquary)).grantRole(keccak256("EMISSION_RATE"), address(this));

            IERC20(poolAdd).approve(address(reliquary), 1); // approve 1 wei to bootstrap the pool
            reliquary.addPool(
                100, // only one pool is necessary
                address(poolAdd), // BTP
                address(parentRewarder),
                ICurves(linearPlateauCurve),
                "sasUSD Pool",
                nftDescriptor,
                true,
                address(this) // can send to the strategy directly.
            );

            rewarder =
                RollingRewarder(ParentRollingRewarder(parentRewarder).createChild(address(asUsd)));
            IERC20(asUsd).approve(address(reliquary), type(uint256).max);
            IERC20(asUsd).approve(address(rewarder), type(uint256).max);
        }

        /// ========== sasUSD Vault Strategy Deploy ===========
        {
            address[] memory ownerArr = new address[](3);
            ownerArr[0] = address(this);
            ownerArr[1] = address(this);
            ownerArr[2] = address(this);

            address[] memory ownerArr1 = new address[](1);
            ownerArr[0] = address(this);

            FeeControllerMock feeControllerMock = new FeeControllerMock();
            feeControllerMock.updateManagementFeeBPS(0);

            asteraVault = new ReaperVaultV2(
                poolAdd,
                "Staked Astera USD",
                "sasUSD",
                type(uint256).max,
                0,
                treasury,
                ownerArr,
                ownerArr,
                address(feeControllerMock)
            );

            SasUsdVaultStrategy implementation = new SasUsdVaultStrategy();
            ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
            strategy = SasUsdVaultStrategy(address(proxy));

            address[] memory ownerArr2 = new address[](2);
            ownerArr2[0] = address(strategy);
            ownerArr2[1] = address(this);
            balancerV3Router = new BalancerV3Router(address(asteraVault), address(this), ownerArr2);

            reliquary.transferFrom(address(this), address(strategy), RELIC_ID); // transfer Relic#1 to strategy.
            strategy.initialize(
                address(asteraVault),
                address(vaultV3),
                address(balancerV3Router),
                ownerArr1,
                ownerArr,
                ownerArr1,
                address(asUsd),
                address(reliquary),
                address(poolAdd)
            );

            // console2.log(address(asteraVault));
            // console2.log(address(vaultV3));
            // console2.log(address(asUSD));
            // console2.log(address(reliquary));
            // console2.log(address(poolAdd));

            asteraVault.addStrategy(address(strategy), 0, 10_000); // 100 % invested
        }

        // ======= asUSD Astera dependencies deploy and configure =======
        {
            asUsdAToken = new AsUsdAToken();
            asUsdVariableDebtToken = new AsUsdVariableDebtToken();
            asUsdOracle = new AsUsdOracle();
            asUsdInterestRateStrategy = new AsUsdIInterestRateStrategy(
                address(deployedContracts.lendingPoolAddressesProvider),
                address(asUsd),
                false,
                address(vaultV3), // balancerVault,
                address(poolAdd),
                1e25,
                2e25, // starts at 2% interest rate
                13e19
            );
            counterAssetPriceFeed =
                new MockV3Aggregator(PRICE_FEED_DECIMALS, int256(1 * 10 ** PRICE_FEED_DECIMALS));
            asUsdInterestRateStrategy.setOracleValues(
                address(counterAssetPriceFeed), 1e26, /* 10% */ 86400
            );

            fixture_configureAsUsd(
                address(deployedContracts.lendingPool),
                address(asUsdAToken),
                address(asUsdVariableDebtToken),
                address(asUsdOracle),
                address(asUsd),
                address(asUsdInterestRateStrategy),
                address(rewarder),
                configAddresses,
                deployedContracts.lendingPoolConfigurator,
                deployedContracts.lendingPoolAddressesProvider
            );

            asUsd.addFacilitator(
                deployedContracts.lendingPool.getReserveData(address(asUsd), false).aTokenAddress,
                "Astera",
                DEFAULT_CAPACITY
            );
            // configAddresses = ConfigAddresses(
            //     address(deployedContracts.asteraDataProvider),
            //     address(deployedContracts.stableStrategy),
            //     address(deployedContracts.volatileStrategy),
            //     address(deployedContracts.treasury),
            //     address(deployedContracts.rewarder),
            //     address(deployedContracts.aTokensAndRatesHelper)
            // );

            tokens.push(address(asUsd));
            commonContracts.aTokens = fixture_getATokens(
                tokens, AsteraDataProvider(configAddresses.asteraDataProvider)
            );

            erc20Tokens.push(ERC20(address(asUsd)));
            // console2.log("Index: ", idx);
            (address _aTokenAddress,) = deployedContracts
                .protocolDataProvider
                .getReserveTokensAddresses(address(asUsd), false);
            aTokens.push(AToken(_aTokenAddress));
            (, address _variableDebtToken) = deployedContracts
                .protocolDataProvider
                .getReserveTokensAddresses(address(asUsd), false);
            variableDebtTokens.push(VariableDebtToken(_variableDebtToken));
        }

        // MAX approve "asteraVault" by all users
        for (uint160 i = 1; i <= 3; i++) {
            vm.prank(address(i)); // address(0x1) == address(1)
            IERC20(poolAdd).approve(address(asteraVault), type(uint256).max);
        }
    }
}
