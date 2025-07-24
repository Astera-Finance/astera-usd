// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

// Astera imports.
import {IReserveInterestRateStrategy} from
    "lib/astera/contracts/interfaces/IReserveInterestRateStrategy.sol";
import {WadRayMath} from "lib/astera/contracts/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "lib/astera/contracts/protocol/libraries/math/PercentageMath.sol";
import {ILendingPoolAddressesProvider} from
    "lib/astera/contracts/interfaces/ILendingPoolAddressesProvider.sol";
import {IAToken} from "lib/astera/contracts/interfaces/IAToken.sol";
import {IVariableDebtToken} from "lib/astera/contracts/interfaces/IVariableDebtToken.sol";
import {VariableDebtToken} from
    "lib/astera/contracts/protocol/tokenization/ERC20/VariableDebtToken.sol";
import {ILendingPool} from "lib/astera/contracts/interfaces/ILendingPool.sol";
import {DataTypes} from "lib/astera/contracts/protocol/libraries/types/DataTypes.sol";
import {ReserveConfiguration} from
    "lib/astera/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {Errors} from "lib/astera/contracts/protocol/libraries/helpers/Errors.sol";

/// Balancer imports
import {IVault as IBalancerVault} from
    "lib/balancer-v3-monorepo/pkg/interfaces/contracts/vault/IVault.sol";

// OZ imports.
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Chainlink.
import {IAggregatorV3Interface} from "contracts/interfaces/IAggregatorV3Interface.sol";

/**
 * @title AsUsdIInterestRateStrategy contract.
 * @notice Implements interest rate calculations using control theory.
 * @dev The model uses Proportional Integrator (PI) control theory. Admin sets optimal utilization
 * rate and strategy auto-adjusts interest rate via Ki variable. Controller error calculated from
 * Balancer stable swap balance incentivized by sdcxUSD staking module.
 * @dev See: https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4844212.
 * @dev IMPORTANT: Do not use as library. One AsUsdIInterestRateStrategy per market only.
 * @author Conclave - Beirao.
 */
contract AsUsdIInterestRateStrategy is IReserveInterestRateStrategy {
    using WadRayMath for uint256;
    using WadRayMath for int256;
    using PercentageMath for uint256;

    /// @dev Ray precision constant (1e27) used for fixed-point calculations.
    int256 private constant RAY = 1e27;
    /// @dev Number of decimal places used for scaling calculations.
    uint256 private constant SCALING_DECIMAL = 18;

    /// @dev Reference to the lending pool addresses provider contract.
    ILendingPoolAddressesProvider public immutable _addressesProvider;
    /// @dev Address of the asset (asUSD) this strategy is associated with.
    address public immutable _asset;
    /// @dev Type of reserve this strategy manages.
    bool public immutable _assetReserveType;

    /// @dev Reference to Balancer vault contract for pool interactions.
    IBalancerVault public immutable _balancerVault;
    /// @dev Address of the Balancer pool this strategy monitors.
    address public _balancerPool;

    /// @dev Minimum error threshold for the PID controller.
    int256 public _minControllerError;
    /// @dev Target utilization rate for the stable pool reserve.
    uint256 public _optimalStablePoolReserveUtilization;
    /// @dev Interest rate that can be manually set.
    uint256 public _manualInterestRate;

    /// @dev Price feed for the counter asset.
    IAggregatorV3Interface public _counterAssetPriceFeed;
    /// @dev Reference price used for peg calculations.
    int256 public _priceFeedReference;
    /// @dev Allowed deviation from the peg price.
    uint256 public _pegMargin;
    /// @dev Maximum time allowed between price updates.
    uint256 public _timeout;

    /// @dev Integral coefficient for PID controller (in RAY units).
    uint256 public _ki;
    /// @dev Timestamp of last interest rate update.
    uint256 public _lastTimestamp;
    /// @dev Accumulated integral error for PID calculations.
    int256 public _errI;

    /// @dev Emitted on PID calculation. If stablePoolReserveUtilization=0, counter asset depegged.
    event PidLog(
        uint256 currentVariableBorrowRate,
        uint256 stablePoolReserveUtilization,
        int256 err,
        int256 controllerErr
    );
    /// @dev Emitted when minimum controller error is set.
    event SetMinControllerError(int256 minControllerError);
    /// @dev Emitted when PID values are set.
    event SetPidValues(uint256 ki);
    /// @dev Emitted when oracle values are set.
    event SetOracleValues(
        address counterAssetPriceFeed, int256 priceFeedReference, uint256 pegMargin, uint256 timeout
    );
    /// @dev Emitted when Balancer pool ID is set.
    event SetBalancerPoolId(address newBalancerPool);
    /// @dev Emitted when manual interest rate is set.
    event SetManualInterestRate(uint256 manualInterestRate);
    /// @dev Emitted when errI value is set.
    event SetErrI(int256 newErrI);

    /**
     * @notice Initializes the interest rate strategy contract.
     * @dev Counter asset MUST be 1$ pegged. setOracleValues() needed at contract creation.
     * @param provider Address of LendingPoolAddressesProvider contract.
     * @param asset Address of asUSD token.
     * @param balancerVault Address of Balancer Vault contract.
     * @param balancerPool Address of the Balancer pool.
     * @param minControllerError Minimum error threshold for PID controller.
     * @param initialErrIValue Initial value for integral error term.
     * @param ki Integral coefficient for PID controller.
     */
    constructor(
        address provider,
        address asset, // asUSD
        bool,
        address balancerVault,
        address balancerPool,
        int256 minControllerError,
        int256 initialErrIValue,
        uint256 ki
    ) {
        /// Astera.
        _asset = asset;
        _assetReserveType = false;
        _addressesProvider = ILendingPoolAddressesProvider(provider);

        /// PID values.
        _ki = ki;
        _errI = initialErrIValue;
        _lastTimestamp = block.timestamp;
        _minControllerError = minControllerError;

        // Balancer.
        _balancerVault = IBalancerVault(balancerVault);
        _balancerPool = balancerPool;
        IERC20[] memory poolTokens_ = IBalancerVault(balancerVault).getPoolTokens(balancerPool);

        _optimalStablePoolReserveUtilization = uint256(RAY) / poolTokens_.length;

        /// Checks.
        // 2 tokens [asset (asUSD), counterAsset (USDC/USDT)].
        if (poolTokens_.length != 2) {
            revert(Errors.VL_INVALID_INPUT);
        }

        if (address(poolTokens_[0]) != asset && address(poolTokens_[1]) != asset) {
            revert(Errors.VL_INVALID_INPUT);
        }

        if (minControllerError <= 0) {
            revert(Errors.LP_BASE_BORROW_RATE_CANT_BE_NEGATIVE);
        }

        if ((transferFunction(initialErrIValue) > uint256(RAY))) {
            revert(Errors.VL_INVALID_INPUT);
        }
    }

    /**
     * @notice Modifier that restricts access to only the pool admin.
     * @dev Reverts if caller is not the pool admin.
     */
    modifier onlyPoolAdmin() {
        if (msg.sender != _addressesProvider.getPoolAdmin()) {
            revert(Errors.VL_CALLER_NOT_POOL_ADMIN);
        }
        _;
    }

    /**
     * @notice Modifier that restricts access to only the lending pool.
     * @dev Reverts if caller is not the lending pool.
     */
    modifier onlyLendingPool() {
        if (msg.sender != _addressesProvider.getLendingPool()) {
            revert(Errors.VL_ACCESS_RESTRICTED_TO_LENDING_POOL);
        }
        _;
    }

    // ----------- admin -----------

    /**
     * @notice Sets the minimum controller error.
     * @dev Only admin can call. Reverts if error <= 0.
     * @param minControllerError New minimum controller error value.
     */
    function setMinControllerError(int256 minControllerError) external onlyPoolAdmin {
        if (minControllerError <= 0) {
            revert(Errors.LP_BASE_BORROW_RATE_CANT_BE_NEGATIVE);
        }

        _minControllerError = minControllerError;

        emit SetMinControllerError(minControllerError);
    }

    /**
     * @notice Sets the PID values for the controller.
     * @dev Only admin can call. Reverts if ki = 0.
     * @param ki The proportional gain value.
     */
    function setPidValues(uint256 ki) external onlyPoolAdmin {
        if (ki == 0) {
            revert(Errors.VL_INVALID_INPUT);
        }
        _ki = ki;

        emit SetPidValues(ki);
    }

    /**
     * @notice Sets the oracle values for the controller.
     * @dev Only admin can call.
     * @param counterAssetPriceFeed Address of counter asset price feed.
     * @param pegMargin Margin for peg value in RAY.
     * @param timeout Pricefeed timeout to detect frozen price feed.
     */
    function setOracleValues(address counterAssetPriceFeed, uint256 pegMargin, uint256 timeout)
        external
        onlyPoolAdmin
    {
        _counterAssetPriceFeed = IAggregatorV3Interface(counterAssetPriceFeed);
        _priceFeedReference = int256(1 * 10 ** uint256(_counterAssetPriceFeed.decimals()));
        _pegMargin = pegMargin;
        _timeout = timeout;

        emit SetOracleValues(counterAssetPriceFeed, _priceFeedReference, pegMargin, timeout);
    }

    /**
     * @notice Sets the poolId variable.
     * @dev Only admin can call. Reverts if poolId = 0.
     * @param newBalancerPool New Balancer pool address.
     */
    function setBalancerPoolId(address newBalancerPool) external onlyPoolAdmin {
        if (newBalancerPool == address(0)) {
            revert(Errors.VL_INVALID_INPUT);
        }
        _balancerPool = newBalancerPool;

        emit SetBalancerPoolId(newBalancerPool);
    }

    /**
     * @notice Sets interest rate manually. When _manualInterestRate != 0, overrides I controller.
     * @dev Only admin can call. Reverts if rate > RAY.
     * @param manualInterestRate Manual interest rate value to set (in RAY).
     */
    function setManualInterestRate(uint256 manualInterestRate) external onlyPoolAdmin {
        if (manualInterestRate > uint256(RAY)) {
            revert(Errors.VL_INVALID_INPUT);
        }
        _manualInterestRate = manualInterestRate;

        emit SetManualInterestRate(manualInterestRate);
    }

    /**
     * @notice Overrides the I controller value.
     * @dev Only admin can call. Reverts if transfer function output > RAY.
     * @param newErrI New _errI value (in RAY).
     */
    function setErrI(int256 newErrI) external onlyPoolAdmin {
        if (transferFunction(newErrI) > uint256(RAY)) {
            revert(Errors.VL_INVALID_INPUT);
        }
        _errI = newErrI;

        emit SetErrI(newErrI);
    }

    // ----------- external -----------

    /**
     * @notice Calculates interest rates based on reserve state and configurations.
     * @dev Only lending pool can call. Kept for compatibility with previous interface.
     * @return Liquidity rate and variable borrow rate.
     */
    function calculateInterestRates(address, address, uint256, uint256, uint256, uint256)
        external
        override
        onlyLendingPool
        returns (uint256, uint256)
    {
        return calculateInterestRates(address(0), 0, 0, 0);
    }

    /**
     * @notice Internal function to calculate interest rates based on reserve state.
     * @dev Kept for compatibility with previous DefaultInterestRateStrategy interface.
     * @return Liquidity rate and variable borrow rate.
     */
    function calculateInterestRates(address, uint256, uint256, uint256)
        internal
        returns (uint256, uint256)
    {
        uint256 stablePoolReserveUtilization;
        int256 err;

        if (address(_counterAssetPriceFeed) == address(0) || isCounterAssetPegged()) {
            /// Calculate the asUSD stablePool reserve utilization.
            stablePoolReserveUtilization = getAsUsdStablePoolReserveUtilization();

            /// PID state update.
            err = getNormalizedError(stablePoolReserveUtilization);
            _errI += int256(_ki).rayMulInt(err * int256(block.timestamp - _lastTimestamp));
            if (_errI < 0) _errI = 0; // Limit the negative accumulation.
            _lastTimestamp = block.timestamp;
        }

        uint256 currentVariableBorrowRate =
            _manualInterestRate != 0 ? _manualInterestRate : transferFunction(_errI);

        emit PidLog(currentVariableBorrowRate, stablePoolReserveUtilization, err, _errI);

        return (0, currentVariableBorrowRate);
    }

    // ----------- view -----------

    /**
     * @notice View function to get current interest rates.
     * @dev Returns current rates. Frontend may need PidLog to get last interest rate.
     * @return currentLiquidityRate Current liquidity rate.
     * @return currentVariableBorrowRate Current variable borrow rate.
     * @return utilizationRate Current utilization rate.
     */
    function getCurrentInterestRates() external view returns (uint256, uint256, uint256) {
        return (
            0,
            _manualInterestRate != 0 ? _manualInterestRate : transferFunction(_errI), // _errI == controler error.
            0
        );
    }

    /**
     * @notice Returns the base variable borrow rate.
     * @return Minimum possible variable borrow rate.
     */
    function baseVariableBorrowRate() public view override returns (uint256) {
        return transferFunction(type(int256).min);
    }

    /**
     * @notice Returns the maximum variable borrow rate.
     * @return Maximum possible variable borrow rate.
     */
    function getMaxVariableBorrowRate() external pure override returns (uint256) {
        return uint256(type(int256).max);
    }

    // ----------- helpers -----------
    /**
     * @notice Calculates the asUSD balance share in the Balancer Pool.
     * @return Share (in RAY) of the asUSD balance.
     */
    function getAsUsdStablePoolReserveUtilization() public view returns (uint256) {
        uint256 totalInPool_;
        uint256 asUsdAmtInPool_;

        (IERC20[] memory tokens_,,, uint256[] memory lastBalancesLiveScaled18_) =
            _balancerVault.getPoolTokenInfo(_balancerPool);

        for (uint256 i = 0; i < tokens_.length; i++) {
            uint256 lastBalance_ = lastBalancesLiveScaled18_[i];
            totalInPool_ += lastBalance_;

            if (address(tokens_[i]) == _asset) asUsdAmtInPool_ = lastBalance_;
        }

        return asUsdAmtInPool_ * uint256(RAY) / totalInPool_;
    }

    /**
     * @notice Normalizes error value for PID controller.
     * @dev For stablePoolReserveUtilization ⊂ [0, Uo] => err ⊂ [-RAY, 0].
     * For stablePoolReserveUtilization ⊂ [Uo, RAY] => err ⊂ [0, RAY].
     * Where Uo = optimalStablePoolReserveUtilization.
     * @param stablePoolReserveUtilization Current utilization rate.
     * @return Normalized error value.
     */
    function getNormalizedError(uint256 stablePoolReserveUtilization)
        internal
        view
        returns (int256)
    {
        int256 err =
            int256(stablePoolReserveUtilization) - int256(_optimalStablePoolReserveUtilization);

        if (int256(stablePoolReserveUtilization) < int256(_optimalStablePoolReserveUtilization)) {
            return err.rayDivInt(int256(_optimalStablePoolReserveUtilization));
        } else {
            return err.rayDivInt(RAY - int256(_optimalStablePoolReserveUtilization));
        }
    }

    /**
     * @notice Transfer function for calculating current variable borrow rate.
     * @param controllerError Current controller error value.
     * @return Calculated variable borrow rate.
     */
    function transferFunction(int256 controllerError) public view returns (uint256) {
        return
            uint256(controllerError > _minControllerError ? controllerError : _minControllerError);
    }

    /**
     * @notice Checks if counter asset is pegged to target value.
     * @dev Uses _pegMargin to determine acceptable deviation from peg.
     * @return True if counter asset properly pegged, false otherwise.
     */
    function isCounterAssetPegged() public view returns (bool) {
        try _counterAssetPriceFeed.latestRoundData() returns (
            uint80 roundID, int256 answer, uint256 startedAt, uint256 timestamp, uint80
        ) {
            // Chainlink integrity checks.
            if (
                roundID == 0 || timestamp == 0 || timestamp > block.timestamp || answer < 0
                    || startedAt == 0 || block.timestamp - timestamp > _timeout
            ) {
                return false;
            }

            // Peg check.
            if (abs(RAY - answer * RAY / _priceFeedReference) > _pegMargin) return false;

            return true;
        } catch {
            return false;
        }
    }

    /**
     * @notice Calculates absolute value of an integer.
     * @param x Input integer.
     * @return Absolute value of x.
     */
    function abs(int256 x) private pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
