// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import "forge-std/console2.sol";
import {TestAsUSD} from "test/helpers/TestAsUSD.sol";
import {ERC20Mock} from "../../helpers/mocks/ERC20Mock.sol";

/// reliquary imports
import "contracts/staking_module/reliquary/Reliquary.sol";
import "contracts/interfaces/IReliquary.sol";
import "contracts/staking_module/reliquary/nft_descriptors/NFTDescriptor.sol";
import "contracts/staking_module/reliquary/curves/LinearPlateauCurve.sol";
import "contracts/staking_module/reliquary/rewarders/RollingRewarder.sol";
import "contracts/staking_module/reliquary/rewarders/ParentRollingRewarder.sol";
import "contracts/interfaces/ICurves.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

/// vault imports
import {ReaperBaseStrategyv4} from "lib/astera-vault/src/ReaperBaseStrategyv4.sol";
import {ReaperVaultV2} from "lib/astera-vault/src/ReaperVaultV2.sol";
import {SasUsdVaultStrategy} from "contracts/staking_module/vault_strategy/SasUsdVaultStrategy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "lib/astera-vault/test/vault/mock/FeeControllerMock.sol";

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
import {IVaultExplorer} from
    "lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultExplorer.sol";
import {TRouter} from "../../helpers/TRouter.sol";

contract TestStakingModule is TestAsUSD, ERC721Holder {
    bytes32 public poolId;
    address public poolAdd;
    IERC20[] public assets;
    IReliquary public reliquary;
    RollingRewarder public rewarder;
    ReaperVaultV2 public asteraVault;
    SasUsdVaultStrategy public strategy;
    IERC20 public mockRewardToken;
    TRouter public tRouter;
    BalancerV3Router public balancerV3Router;

    // Linear function config (to config)
    uint256 public slope = 100; // Increase of multiplier every second
    uint256 public minMultiplier = 365 days * 100; // Arbitrary (but should be coherent with slope)
    uint256 public plateau = 10 days;
    uint256 private constant RELIC_ID = 1;

    uint256 public indexAsUsd;
    uint256 public indexUsdc;

    function setUp() public virtual override {
        super.setUp();
        vm.selectFork(forkIdEth);

        tRouter = new TRouter(vaultV3);
        vm.startPrank(userA);
        asUSD.approve(address(tRouter), type(uint256).max);
        usdc.approve(address(tRouter), type(uint256).max);
        vm.stopPrank();

        /// ======= Balancer Pool Deploy =======
        {
            assets.push(IERC20(address(usdc)));
            assets.push(IERC20(address(asUSD)));

            IERC20[] memory assetsSorted = sort(assets);
            assets[0] = assetsSorted[0];
            assets[1] = assetsSorted[1];

            // balancer stable pool creation
            poolAdd = createStablePool(assets, 2500, userA);

            // join Pool
            IERC20[] memory setupPoolTokens = IVaultExplorer(vaultV3).getPoolTokens(poolAdd);

            uint256 indexAsUsdTemp;
            uint256 indexUsdcTemp;
            for (uint256 i = 0; i < setupPoolTokens.length; i++) {
                if (setupPoolTokens[i] == asUSD) indexAsUsdTemp = i;
                if (setupPoolTokens[i] == usdc) indexUsdcTemp = i;
            }

            uint256[] memory amountsToAdd = new uint256[](setupPoolTokens.length);
            amountsToAdd[indexAsUsdTemp] = INITIAL_ASUSD_AMT;
            amountsToAdd[indexUsdcTemp] = INITIAL_USDC_AMT;

            vm.prank(userA);
            tRouter.initialize(poolAdd, assets, amountsToAdd);

            vm.prank(userA);
            IERC20(poolAdd).transfer(address(this), 1);

            for (uint256 i = 0; i < assets.length; i++) {
                if (assets[i] == asUSD) indexAsUsd = i;
                if (assets[i] == IERC20(address(usdc))) {
                    indexAsUsd = i;
                }
            }
        }

        /// ========= Reliquary Deploy =========
        {
            mockRewardToken = IERC20(address(new ERC20Mock(18)));
            reliquary =
                new Reliquary(address(mockRewardToken), 0, "Reliquary sasUSD", "sasUSD Relic");
            address linearPlateauCurve =
                address(new LinearPlateauCurve(slope, minMultiplier, plateau));

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
                RollingRewarder(ParentRollingRewarder(parentRewarder).createChild(address(asUSD)));
            IERC20(asUSD).approve(address(reliquary), type(uint256).max);
            IERC20(asUSD).approve(address(rewarder), type(uint256).max);
        }

        /// ========== sasUSD Vault Strategy Deploy ===========
        {
            address[] memory interactors = new address[](1);
            interactors[0] = address(this);
            balancerV3Router = new BalancerV3Router(address(vaultV3), address(this), interactors);

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

            reliquary.transferFrom(address(this), address(strategy), RELIC_ID); // transfer Relic#1 to strategy.
            strategy.initialize(
                address(asteraVault),
                address(vaultV3),
                address(balancerV3Router),
                ownerArr1,
                ownerArr,
                ownerArr1,
                address(asUSD),
                address(reliquary),
                address(poolAdd)
            );

            // console2.log(address(asteraVault));
            // console2.log(address(vaultV3));
            // console2.log(address(asUSD));
            // console2.log(address(reliquary));
            // console2.log(address(poolAdd));

            asteraVault.addStrategy(address(strategy), 0, 10_000); // 100 % invested

            address[] memory interactors2 = new address[](1);
            interactors2[0] = address(strategy);
            balancerV3Router.setInteractors(interactors2);
        }

        // MAX approve "asteraVault" by all users
        for (uint160 i = 1; i <= 3; i++) {
            vm.startPrank(address(i)); // address(0x1) == address(1)

            IERC20(poolAdd).approve(address(asteraVault), type(uint256).max);

            asUSD.approve(address(balancerV3Router), type(uint256).max);
            usdc.approve(address(balancerV3Router), type(uint256).max);

            IERC20(poolAdd).approve(address(balancerV3Router), type(uint256).max);

            vm.stopPrank();
        }
    }

    function testVariables() public {
        // reliquary
        assertEq(reliquary.emissionRate(), 0);
        assertEq(rewarder.distributionPeriod(), 3 days);

        // vault
        assertEq(asteraVault.tvlCap(), type(uint256).max);
        assertEq(asteraVault.managementFeeCapBPS(), 0);
        assertEq(asteraVault.tvlCap(), type(uint256).max);
        assertEq(asteraVault.totalAllocBPS(), 10_000);
        assertEq(asteraVault.totalAllocated(), 0);
        assertEq(asteraVault.emergencyShutdown(), false);
        assertEq(address(asteraVault.token()), poolAdd);
        assertEq(reliquary.isApprovedOrOwner(address(strategy), RELIC_ID), true);

        // strategy
        assertEq(address(strategy.asUSD()), address(asUSD));
        assertEq(address(strategy.reliquary()), address(reliquary));
        assertEq(address(strategy.balancerVault()), address(vaultV3));
        assertNotEq(strategy.asUsdIndex(), type(uint256).max);
        assertEq(strategy.minBPTAmountOut(), 1);
        assertEq(strategy.want(), poolAdd);
        assertEq(strategy.vault(), address(asteraVault));
        assertEq(address(strategy.swapper()), address(0));
    }

    function testDepositWithdraw(uint256 _seedAmt, uint256 _seedFunding, uint256 _seedDeltaTime)
        public
    {
        uint256 amt = bound(_seedAmt, 1e15, IERC20(poolAdd).balanceOf(userA));
        uint256 funding = bound(_seedFunding, 1e15, asUSD.balanceOf(address(this)));
        uint256 deltaTime = bound(_seedDeltaTime, 0, rewarder.distributionPeriod());

        vm.prank(userA);
        asteraVault.deposit(amt);

        assertEq(amt, asteraVault.balanceOf(userA));
        assertEq(amt, IERC20(poolAdd).balanceOf(address(asteraVault)));

        rewarder.fund(funding);

        skip(deltaTime);

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        assertEq(0, strategy.balanceOfWant());
        assertEq(amt, IERC20(poolAdd).balanceOf(address(reliquary)));

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        assertEq(0, IERC20(poolAdd).balanceOf(address(asteraVault)));
        assertApproxEqRel(
            amt + funding * deltaTime / rewarder.distributionPeriod(),
            IERC20(poolAdd).balanceOf(address(reliquary)),
            1e14
        ); // 0,01%

        uint256 balanceUserABefore = IERC20(poolAdd).balanceOf(userA);

        skip(7 hours); // For 100% profit degradation.

        vm.prank(userA);
        asteraVault.withdrawAll();

        assertApproxEqRel(0, IERC20(poolAdd).balanceOf(address(reliquary)), 1e14); // 0,01%

        assertApproxEqRel(
            balanceUserABefore + amt + funding * deltaTime / rewarder.distributionPeriod(),
            IERC20(poolAdd).balanceOf(userA),
            1e14
        ); // 0,01%
    }

    function testSlippageProtectionCheck(
        uint256 _seedAmt,
        uint256 _seedFunding,
        uint256 _seedDeltaTime
    ) public {
        uint256 amt = bound(_seedAmt, 1e15, IERC20(poolAdd).balanceOf(userA));
        uint256 funding = bound(_seedFunding, 1e15, asUSD.balanceOf(address(this)));
        uint256 deltaTime = bound(_seedDeltaTime, 0, type(uint40).max);

        vm.prank(userA);
        asteraVault.deposit(amt);

        assertEq(amt, asteraVault.balanceOf(userA));
        assertEq(amt, IERC20(poolAdd).balanceOf(address(asteraVault)));

        rewarder.fund(funding);

        skip(deltaTime);
        vm.expectRevert(SasUsdVaultStrategy.SasUsdVaultStrategy__NO_SLIPPAGE_PROTECTION.selector);
        strategy.harvest();
    }

    function testVaultEmergencyWithdraw1(
        uint256 _seedAmt,
        uint256 _seedFunding,
        uint256 _seedDeltaTime
    ) public {
        uint256 amt = bound(_seedAmt, 1e15, IERC20(poolAdd).balanceOf(userA));
        uint256 funding = bound(_seedFunding, 1e15, asUSD.balanceOf(address(this)));
        uint256 deltaTime = bound(_seedDeltaTime, 0, rewarder.distributionPeriod());

        vm.prank(userA);
        asteraVault.deposit(amt);

        assertEq(amt, asteraVault.balanceOf(userA));
        assertEq(amt, IERC20(poolAdd).balanceOf(address(asteraVault)));

        rewarder.fund(funding);

        skip(deltaTime);

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        asteraVault.setEmergencyShutdown(true);
        assertEq(asteraVault.emergencyShutdown(), true);

        assertEq(0, IERC20(poolAdd).balanceOf(address(asteraVault)));
        assertApproxEqRel(
            amt + funding * deltaTime / rewarder.distributionPeriod(),
            IERC20(poolAdd).balanceOf(address(reliquary)),
            1e14
        ); // 0,01%

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        assertEq(0, IERC20(poolAdd).balanceOf(address(reliquary)));
        assertApproxEqRel(
            amt + funding * deltaTime / rewarder.distributionPeriod(),
            IERC20(poolAdd).balanceOf(address(asteraVault)),
            1e14
        ); // 0,01%

        // withdraw
        uint256 balanceUserABefore = IERC20(poolAdd).balanceOf(userA);

        skip(7 hours); // For 100% profit degradation.

        vm.prank(userA);
        asteraVault.withdrawAll();

        assertApproxEqRel(0, IERC20(poolAdd).balanceOf(address(reliquary)), 1e14); // 0,01%

        assertApproxEqRel(
            balanceUserABefore + amt + funding * deltaTime / rewarder.distributionPeriod(),
            IERC20(poolAdd).balanceOf(userA),
            1e14
        ); // 0,01%
    }

    function testVaultEmergencyWithdraw2(
        uint256 _seedAmt,
        uint256 _seedFunding,
        uint256 _seedDeltaTime
    ) public {
        uint256 amt = bound(_seedAmt, 1e15, IERC20(poolAdd).balanceOf(userA));
        uint256 funding = bound(_seedFunding, 1e15, asUSD.balanceOf(address(this)));
        uint256 deltaTime = bound(_seedDeltaTime, 0, rewarder.distributionPeriod());

        vm.prank(userA);
        asteraVault.deposit(amt);

        assertEq(amt, asteraVault.balanceOf(userA));
        assertEq(amt, IERC20(poolAdd).balanceOf(address(asteraVault)));

        rewarder.fund(funding);

        skip(deltaTime);

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        asteraVault.setEmergencyShutdown(true);
        assertEq(asteraVault.emergencyShutdown(), true);

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        assertEq(0, IERC20(poolAdd).balanceOf(address(reliquary)));
        assertApproxEqRel(
            amt + funding * deltaTime / rewarder.distributionPeriod(),
            IERC20(poolAdd).balanceOf(address(asteraVault)),
            1e14
        ); // 0,01%

        // withdraw
        uint256 balanceUserABefore = IERC20(poolAdd).balanceOf(userA);

        skip(7 hours); // For 100% profit degradation.

        vm.prank(userA);
        asteraVault.withdrawAll();

        assertApproxEqRel(0, IERC20(poolAdd).balanceOf(address(reliquary)), 1e14); // 0,01%

        assertApproxEqRel(
            balanceUserABefore + amt + funding * deltaTime / rewarder.distributionPeriod(),
            IERC20(poolAdd).balanceOf(userA),
            1e14
        ); // 0,01%
    }

    function testStrategyEmergencyExit(
        uint256 _seedAmt,
        uint256 _seedFunding,
        uint256 _seedDeltaTime
    ) public {
        uint256 amt = bound(_seedAmt, 1e15, IERC20(poolAdd).balanceOf(userA));
        uint256 funding = bound(_seedFunding, 1e15, asUSD.balanceOf(address(this)));
        uint256 deltaTime = bound(_seedDeltaTime, 0, rewarder.distributionPeriod());

        vm.prank(userA);
        asteraVault.deposit(amt);

        assertEq(amt, asteraVault.balanceOf(userA));
        assertEq(amt, IERC20(poolAdd).balanceOf(address(asteraVault)));

        rewarder.fund(funding);

        skip(deltaTime);

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        strategy.setEmergencyExit();
        assertEq(strategy.emergencyExit(), true);

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        assertEq(0, IERC20(poolAdd).balanceOf(address(reliquary)));
        assertApproxEqRel(
            amt + funding * deltaTime / rewarder.distributionPeriod(),
            IERC20(poolAdd).balanceOf(address(asteraVault)),
            1e14
        ); // 0,01%

        // withdraw
        uint256 balanceUserABefore = IERC20(poolAdd).balanceOf(userA);

        skip(7 hours); // For 100% profit degradation.

        vm.prank(userA);
        asteraVault.withdrawAll();

        assertApproxEqRel(0, IERC20(poolAdd).balanceOf(address(reliquary)), 1e14); // 0,01%

        assertApproxEqRel(
            balanceUserABefore + amt + funding * deltaTime / rewarder.distributionPeriod(),
            IERC20(poolAdd).balanceOf(userA),
            1e14
        ); // 0,01%
    }

    function testStrategyAndVaultEmergencyExit0(
        uint256 _seedAmt,
        uint256 _seedFunding,
        uint256 _seedDeltaTime
    ) public {
        uint256 amt = bound(_seedAmt, 1e15, IERC20(poolAdd).balanceOf(userA));
        uint256 funding = bound(_seedFunding, 1e15, asUSD.balanceOf(address(this)));
        uint256 deltaTime = bound(_seedDeltaTime, 0, rewarder.distributionPeriod());

        vm.prank(userA);
        asteraVault.deposit(amt);

        assertEq(amt, asteraVault.balanceOf(userA));
        assertEq(amt, IERC20(poolAdd).balanceOf(address(asteraVault)));

        rewarder.fund(funding);

        skip(deltaTime);

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        strategy.setEmergencyExit();
        assertEq(strategy.emergencyExit(), true);
        asteraVault.setEmergencyShutdown(true);
        assertEq(asteraVault.emergencyShutdown(), true);

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        assertEq(0, IERC20(poolAdd).balanceOf(address(reliquary)));
        assertApproxEqRel(
            amt + funding * deltaTime / rewarder.distributionPeriod(),
            IERC20(poolAdd).balanceOf(address(asteraVault)),
            1e14
        ); // 0,01%

        // withdraw
        uint256 balanceUserABefore = IERC20(poolAdd).balanceOf(userA);

        skip(7 hours); // For 100% profit degradation.

        vm.prank(userA);
        asteraVault.withdrawAll();

        assertApproxEqRel(0, IERC20(poolAdd).balanceOf(address(reliquary)), 1e14); // 0,01%
        assertApproxEqRel(
            balanceUserABefore + amt + funding * deltaTime / rewarder.distributionPeriod(),
            IERC20(poolAdd).balanceOf(userA),
            1e14
        ); // 0,01%
    }

    function testStrategyAndVaultEmergencyExitWithReliquaryPaused(
        uint256 _seedAmt,
        uint256 _seedFunding,
        uint256 _seedDeltaTime
    ) public {
        uint256 amt = bound(_seedAmt, 1e15, IERC20(poolAdd).balanceOf(userA));
        uint256 funding = bound(_seedFunding, 1e15, asUSD.balanceOf(address(this)));
        uint256 deltaTime = bound(_seedDeltaTime, 0, rewarder.distributionPeriod());

        vm.prank(userA);
        asteraVault.deposit(amt);

        assertEq(amt, asteraVault.balanceOf(userA));
        assertEq(amt, IERC20(poolAdd).balanceOf(address(asteraVault)));

        rewarder.fund(funding);

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();
        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        // full emergency
        strategy.setEmergencyExit();
        asteraVault.setEmergencyShutdown(true);
        reliquary.pause();

        skip(deltaTime);

        strategy.setMinBPTAmountOut(2);
        strategy.harvest();

        assertEq(0, IERC20(poolAdd).balanceOf(address(reliquary)));
        assertEq(funding, IERC20(asUSD).balanceOf(address(rewarder)));
        assertApproxEqRel(amt, IERC20(poolAdd).balanceOf(address(asteraVault)), 1e14); // 0,01%

        // withdraw
        uint256 balanceUserABefore = IERC20(poolAdd).balanceOf(userA);

        skip(7 hours); // For 100% profit degradation.

        vm.prank(userA);
        asteraVault.withdrawAll();

        assertApproxEqRel(0, IERC20(poolAdd).balanceOf(address(reliquary)), 1e14); // 0,01%
        assertEq(funding, IERC20(asUSD).balanceOf(address(rewarder)));
        assertApproxEqRel(balanceUserABefore + amt, IERC20(poolAdd).balanceOf(userA), 1e14); // 0,01%
    }
}
