// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "forge-std/console2.sol";

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

// Balancer
import {TestAsUSDAndLendAndStaking} from "test/helpers/TestAsUSDAndLendAndStaking.sol";
import {ERC20Mock} from "../../helpers/mocks/ERC20Mock.sol";

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
import {ReaperBaseStrategyv4} from "lib/astera-vault/src/ReaperBaseStrategyv4.sol";
import {ReaperVaultV2} from "lib/astera-vault/src/ReaperVaultV2.sol";
import {SasUsdVaultStrategy} from "contracts/staking_module/vault_strategy/SasUsdVaultStrategy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "lib/astera-vault/test/vault/mock/FeeControllerMock.sol";

// AsUSD
import {AsUSD} from "contracts/tokens/AsUSD.sol";
import {AsUsdIInterestRateStrategy} from
    "contracts/facilitators/astera/interest_strategy/AsUsdIInterestRateStrategy.sol";
import {AsUsdOracle} from "contracts/facilitators/astera/oracle/AsUSDOracle.sol";
import {AsUsdAToken} from "contracts/facilitators/astera/token/AsUsdAToken.sol";
import {AsUsdVariableDebtToken} from
    "contracts/facilitators/astera/token/AsUsdVariableDebtToken.sol";
import {MockV3Aggregator} from "test/helpers/mocks/MockV3Aggregator.sol";
import {ILendingPool} from "lib/astera/contracts/interfaces/ILendingPool.sol";

import {IERC20Detailed} from
    "lib/astera/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol";
import {TRouter} from "test/helpers/TRouter.sol";
import {IVaultExplorer} from
    "lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVaultExplorer.sol";

import {BalancerV3Router} from
    "contracts/staking_module/vault_strategy/libraries/BalancerV3Router.sol";

contract TestBalancerV3Router is TestAsUSDAndLendAndStaking {
    BalancerV3Router public router;

    IERC20 public counterAsset2;
    address public poolAdd2;
    IERC20[] public assets2;

    uint256 indexAsUsd2;
    uint256 indexCounterAsset2;

    function setUp() public override {
        super.setUp();

        counterAsset2 = IERC20(address(new ERC20Mock(8)));

        /// initial mint
        ERC20Mock(address(counterAsset2)).mint(userA, INITIAL_COUNTER_ASSET_AMT);
        ERC20Mock(address(counterAsset2)).mint(userB, INITIAL_COUNTER_ASSET_AMT);
        ERC20Mock(address(counterAsset2)).mint(userC, INITIAL_COUNTER_ASSET_AMT);
        vm.startPrank(userC);
        ERC20Mock(address(asUsd)).mint(userC, INITIAL_ASUSD_AMT);
        vm.stopPrank();

        vm.startPrank(userC); // address(0x1) == address(1)
        asUsd.approve(address(vaultV3), type(uint256).max);
        counterAsset2.approve(address(vaultV3), type(uint256).max);
        asUsd.approve(address(tRouter), type(uint256).max);
        counterAsset2.approve(address(tRouter), type(uint256).max);
        vm.stopPrank();

        address[] memory interactors = new address[](4);
        interactors[0] = address(this);
        interactors[1] = address(userA);
        interactors[2] = address(userB);
        interactors[3] = address(userC);

        router = new BalancerV3Router(vaultV3, address(this), interactors);

        // ======= Balancer Pool 2 Deploy =======
        {
            assets2.push(IERC20(address(counterAsset2)));
            assets2.push(IERC20(address(asUsd)));

            IERC20[] memory assetsSorted = sort(assets2);
            assets2[0] = assetsSorted[0];
            assets2[1] = assetsSorted[1];

            // balancer stable pool creation
            poolAdd2 = createStablePool(assets2, 2500, userC);

            // join Pool
            IERC20[] memory setupPoolTokens = IVaultExplorer(vaultV3).getPoolTokens(poolAdd2);

            for (uint256 i = 0; i < setupPoolTokens.length; i++) {
                if (setupPoolTokens[i] == asUsd) indexAsUsd2 = i;
                if (setupPoolTokens[i] == IERC20(address(counterAsset2))) indexCounterAsset2 = i;
            }

            uint256[] memory amountsToAdd = new uint256[](setupPoolTokens.length);
            amountsToAdd[indexAsUsd2] = 1_000_000e18;
            amountsToAdd[indexCounterAsset2] = 1_000_000e8;

            vm.prank(userC);
            tRouter.initialize(poolAdd2, assets2, amountsToAdd);

            vm.prank(userC);
            IERC20(poolAdd2).transfer(address(this), 1);

            for (uint256 i = 0; i < assets2.length; i++) {
                if (assets2[i] == asUsd) indexAsUsd = i;
                if (assets2[i] == IERC20(address(counterAsset2))) {
                    indexCounterAsset = i;
                }
            }
        }

        // all user approve max router
        for (uint256 i = 0; i < interactors.length; i++) {
            vm.startPrank(interactors[i]);
            asUsd.approve(address(router), type(uint256).max);
            counterAsset.approve(address(router), type(uint256).max);
            counterAsset2.approve(address(router), type(uint256).max);
            IERC20(poolAdd).approve(address(router), type(uint256).max);
            IERC20(poolAdd2).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    // Make sure 18decScaled(balancesRaw_) == lastBalancesLiveScaled18_
    function test_getPoolTokenInfo() public {
        {
            (
                IERC20[] memory tokens_,
                ,
                uint256[] memory balancesRaw_,
                uint256[] memory lastBalancesLiveScaled18_
            ) = IVaultExplorer(vaultV3).getPoolTokenInfo(poolAdd2);

            for (uint256 i = 0; i < tokens_.length; i++) {
                console2.log("token ::: ", address(tokens_[i]));
                console2.log("balanceRaw              ::: ", balancesRaw_[i]);
                console2.log("lastBalanceLiveScaled18 ::: ", lastBalancesLiveScaled18_[i]);
                console2.log("--------------------------------");

                assertEq(scaleDecimals(balancesRaw_[i], tokens_[i]), lastBalancesLiveScaled18_[i]);
            }
        }

        // add liquidity
        uint256[] memory amountsToAdd = new uint256[](assets2.length);
        amountsToAdd[indexAsUsd2] = 101100e18;
        amountsToAdd[indexCounterAsset2] = 1900e8;

        vm.startPrank(userB);
        router.addLiquidityUnbalanced(poolAdd2, amountsToAdd, 0);
        vm.stopPrank();

        {
            (
                IERC20[] memory tokens_,
                ,
                uint256[] memory balancesRaw_,
                uint256[] memory lastBalancesLiveScaled18_
            ) = IVaultExplorer(vaultV3).getPoolTokenInfo(poolAdd2);

            for (uint256 i = 0; i < tokens_.length; i++) {
                console2.log("token ::: ", address(tokens_[i]));
                console2.log("balanceRaw              ::: ", balancesRaw_[i]);
                console2.log("lastBalanceLiveScaled18 ::: ", lastBalancesLiveScaled18_[i]);
                console2.log("--------------------------------");

                assertEq(scaleDecimals(balancesRaw_[i], tokens_[i]), lastBalancesLiveScaled18_[i]);
            }
        }

        // remove liquidity
        vm.startPrank(userB);
        router.removeLiquiditySingleTokenExactIn(poolAdd2, 0, IERC20(poolAdd2).balanceOf(userB), 1);
        vm.stopPrank();

        {
            (
                IERC20[] memory tokens_,
                ,
                uint256[] memory balancesRaw_,
                uint256[] memory lastBalancesLiveScaled18_
            ) = IVaultExplorer(vaultV3).getPoolTokenInfo(poolAdd2);

            for (uint256 i = 0; i < tokens_.length; i++) {
                console2.log("token ::: ", address(tokens_[i]));
                console2.log("balanceRaw              ::: ", balancesRaw_[i]);
                console2.log("lastBalanceLiveScaled18 ::: ", lastBalancesLiveScaled18_[i]);
                console2.log("--------------------------------");

                assertEq(scaleDecimals(balancesRaw_[i], tokens_[i]), lastBalancesLiveScaled18_[i]);
            }
        }
    }

    function test_BalancerV3Router1() public {
        uint256[] memory amounts = new uint256[](assets.length);
        amounts[0] = 1e18;
        amounts[1] = 1e18;

        // balance before
        uint256 asUsdBalanceBefore = asUsd.balanceOf(userB);
        uint256 counterAssetBalanceBefore = counterAsset.balanceOf(userB);

        vm.startPrank(userB);
        router.addLiquidityUnbalanced(poolAdd, amounts, 0);
        vm.stopPrank();

        assertEq(asUsd.balanceOf(userB), asUsdBalanceBefore - amounts[0]);
        assertEq(counterAsset.balanceOf(userB), counterAssetBalanceBefore - amounts[1]);

        // remove liquidity
        uint256[] memory amountsOut = new uint256[](assets.length);
        amountsOut[0] = 1e18;
        amountsOut[1] = 1e18;

        // balance before remove liquidity
        uint256 asUsdBalanceBeforeRemove = asUsd.balanceOf(userB);
        uint256 counterAssetBalanceBeforeRemove = counterAsset.balanceOf(userB);

        vm.startPrank(userB);
        router.removeLiquiditySingleTokenExactIn(poolAdd, 0, IERC20(poolAdd).balanceOf(userB), 1);
        vm.stopPrank();

        console2.log(
            "asUsd.balanceOf(userB) ::: ", asUsd.balanceOf(userB) - asUsdBalanceBeforeRemove
        );
        console2.log(
            "counterAsset.balanceOf(userB) ::: ",
            counterAsset.balanceOf(userB) - counterAssetBalanceBeforeRemove
        );

        assertApproxEqRel(asUsd.balanceOf(userB) - asUsdBalanceBeforeRemove, 2e18, 1e16);
        assertEq(IERC20(poolAdd).balanceOf(userB), 0);
    }

    function test_BalancerV3Router2() public {
        uint256[] memory amounts = new uint256[](assets.length);
        amounts[0] = 1e18;
        amounts[1] = 1e18;

        // balance before
        uint256 asUsdBalanceBefore = asUsd.balanceOf(userB);
        uint256 counterAssetBalanceBefore = counterAsset.balanceOf(userB);

        vm.startPrank(userB);
        router.addLiquidityUnbalanced(poolAdd, amounts, 0);
        vm.stopPrank();

        assertEq(asUsd.balanceOf(userB), asUsdBalanceBefore - amounts[0]);
        assertEq(counterAsset.balanceOf(userB), counterAssetBalanceBefore - amounts[1]);

        // remove liquidity
        uint256[] memory amountsOut = new uint256[](assets.length);
        amountsOut[0] = 1e18;
        amountsOut[1] = 1e18;

        // balance before remove liquidity
        uint256 asUsdBalanceBeforeRemove = asUsd.balanceOf(userB);
        uint256 counterAssetBalanceBeforeRemove = counterAsset.balanceOf(userB);

        vm.startPrank(userB);
        router.removeLiquiditySingleTokenExactIn(poolAdd, 1, IERC20(poolAdd).balanceOf(userB), 1);
        vm.stopPrank();

        console2.log(
            "asUsd.balanceOf(userB) ::: ", asUsd.balanceOf(userB) - asUsdBalanceBeforeRemove
        );
        console2.log(
            "counterAsset.balanceOf(userB) ::: ",
            counterAsset.balanceOf(userB) - counterAssetBalanceBeforeRemove
        );

        assertApproxEqRel(
            counterAsset.balanceOf(userB) - counterAssetBalanceBeforeRemove, 2e18, 1e16
        );
        assertEq(IERC20(poolAdd).balanceOf(userB), 0);
    }

    function test_TRouter() public {
        assertEq(assets.length, 2);
        assertNotEq(poolAdd, address(0));

        uint256[] memory amounts = new uint256[](assets.length);
        amounts[0] = 1e18;
        amounts[1] = 1e18;

        uint256 asUsdBalanceBefore = asUsd.balanceOf(userB);
        uint256 counterAssetBalanceBefore = counterAsset.balanceOf(userB);

        vm.startPrank(userB);
        tRouter.addLiquidity(poolAdd, userB, amounts);

        assertEq(counterAsset.balanceOf(userB), counterAssetBalanceBefore - amounts[0]);
        assertEq(asUsd.balanceOf(userB), asUsdBalanceBefore - amounts[1]);

        amounts[0] = 0;
        amounts[1] = 1e18;

        // get BPT token address
        IERC20[] memory tokens = IVaultExplorer(vaultV3).getPoolTokens(poolAdd);
        console2.log("bptToken ::: ", tokens.length);

        IERC20(poolAdd).approve(address(tRouter), type(uint256).max);

        tRouter.removeLiquidity(poolAdd, userB, amounts);
        vm.stopPrank();

        assertEq(counterAsset.balanceOf(userB), counterAssetBalanceBefore);
        assertEq(asUsd.balanceOf(userB), asUsdBalanceBefore - 1e18);

        asUsdBalanceBefore = asUsd.balanceOf(userB);
        counterAssetBalanceBefore = counterAsset.balanceOf(userB);

        vm.prank(userB);
        tRouter.swapSingleTokenExactIn(poolAdd, asUsd, IERC20(address(counterAsset)), 1e18 / 2, 0);

        assertApproxEqRel(asUsd.balanceOf(userB), asUsdBalanceBefore - 1e18 / 2, 1e16); // 1%
        assertApproxEqRel(counterAsset.balanceOf(userB), counterAssetBalanceBefore + 1e18 / 2, 1e16); // 1%
    }

    /// ================ Helper functions ================

    /**
     * @notice Scales an amount to the appropriate number of decimals (18) based on the token's decimal precision.
     * @param amount The value representing the amount to be scaled.
     * @param token The address of the IERC20 token contract.
     * @return The scaled amount.
     */
    function scaleDecimals(uint256 amount, IERC20 token) internal view returns (uint256) {
        return amount * 10 ** (18 - ERC20(address(token)).decimals());
    }
}
