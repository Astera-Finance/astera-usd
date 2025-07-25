// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "contracts/interfaces/IReliquary.sol";
import "contracts/interfaces/IRewarder.sol";
import "./libraries/ReliquaryLogic.sol";
import "./libraries/ReliquaryEvents.sol";
import "./libraries/ReliquaryRehypothecationLogic.sol";
import "contracts/interfaces/IParentRollingRewarder.sol";
import "contracts/interfaces/INFTDescriptor.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Reliquary
 * @author Conclave - Justin Bebis, Zokunei, Beirao, Goober
 *
 * @notice This system is designed to manage incentives for deposited assets such that
 * behaviors can be programmed on a per-pool basis using maturity levels. Stake in a
 * pool, also referred to as "position," is represented by means of an NFT called a
 * "Relic." Each position has a "maturity" which captures the age of the position.
 *
 * @notice Deposits are tracked by Relic ID instead of by user. This allows for
 * increased composability without affecting accounting logic too much, and users can
 * trade their Relics without withdrawing liquidity or affecting the position's maturity.
 */
contract Reliquary is
    IReliquary,
    // Multicall,
    ERC721Enumerable,
    AccessControlEnumerable,
    ReentrancyGuard,
    Pausable
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @dev Access control roles.
    bytes32 private constant OPERATOR = keccak256("OPERATOR");
    bytes32 private constant GUARDIAN = keccak256("GUARDIAN");
    bytes32 private constant EMISSION_RATE = keccak256("EMISSION_RATE");

    /// @dev Address of the reward token contract.
    address public immutable rewardToken;
    /// @dev value of emission rate.
    uint256 public emissionRate;
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;
    /// @dev Nonce to use for new relicId.
    uint256 private idNonce;
    /// @dev Treasury receive funds from rehypotheration claim.
    address public treasury;

    /// @dev Info of each Reliquary pool.
    PoolInfo[] private poolInfo;
    /// @dev Info of each staked position.
    mapping(uint256 => PositionInfo) internal positionForId;

    /**
     * @dev Constructs and initializes the contract.
     * @param _rewardToken The reward token contract address.
     * @param _emissionRate The contract address for the EmissionRate, which will return the emission rate.
     */
    constructor(
        address _rewardToken,
        uint256 _emissionRate,
        string memory _name,
        string memory _symbol
    ) ERC721(_name, _symbol) {
        rewardToken = _rewardToken;
        emissionRate = _emissionRate;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // -------------- admin functions --------------
    /**
     * @notice Pause all functions except `emergencyWithdraw()`.
     * @dev Restricted to the GUARDIAN role.
     */
    function pause() public onlyRole(GUARDIAN) {
        _pause();
    }

    /**
     * @notice Unpause.
     * @dev Restricted to the OPERATOR role.
     */
    function unpause() public onlyRole(OPERATOR) {
        _unpause();
    }

    /**
     * @notice Sets a new EmissionRate for overall rewardToken emissions. Can only be called with the proper role.
     * @param _emissionRate The contract address for the EmissionRate, which will return the base emission rate.
     */
    function setEmissionRate(uint256 _emissionRate)
        external
        whenNotPaused
        onlyRole(EMISSION_RATE)
    {
        ReliquaryLogic._massUpdatePools(poolInfo, emissionRate, totalAllocPoint);
        emissionRate = _emissionRate;
        emit ReliquaryEvents.LogSetEmissionRate(_emissionRate);
    }

    /**
     * @notice Add a new pool for the specified LP. Can only be called by an operator.
     * @dev max number of pools 255 (uint8)
     * Bootstrap the newly created pool with 1 wei of poolToken to avoid any reward losses.
     * @param _allocPoint The allocation points for the new pool.
     * @param _poolToken Address of the pooled ERC-20 token.
     * @param _rewarder Address of the rewarder delegate.
     * @param _curve Curve that will be applied to the pool.
     * @param _name Name of pool to be displayed in NFT image.
     * @param _nftDescriptor The contract address for NFTDescriptor, which will return the token URI.
     * @param _allowPartialWithdrawals Whether users can withdraw less than their entire position. A value of false
     * @param _to Where the 1 wei bootstrap is sent to.
     * will also disable shift and split functionality. This is useful for adding pools with decreasing levelMultipliers.
     */
    function addPool(
        uint256 _allocPoint,
        address _poolToken,
        address _rewarder,
        ICurves _curve,
        string memory _name,
        address _nftDescriptor,
        bool _allowPartialWithdrawals,
        address _to
    ) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        ReliquaryLogic._massUpdatePools(poolInfo, emissionRate, totalAllocPoint);

        // ----------------- Intensive curve compatibility checks.
        {
            if (_poolToken == rewardToken) revert Reliquary__REWARD_TOKEN_AS_POOL_TOKEN();

            // Multiplier at f(0) must not be 0.
            if (_curve.getFunction(0) == 0) {
                revert Reliquary__MULTIPLIER_AT_LEVEL_ZERO_SHOULD_BE_GT_ZERO();
            }

            // MAX_SUPPLY_ALLOWED in 10 years should not round down at 0 in case of division.
            uint256 tenYears_ = 365 days * 10;
            if (ACC_REWARD_PRECISION < MAX_SUPPLY_ALLOWED * _curve.getFunction(tenYears_)) {
                revert Reliquary__REWARD_PRECISION_ISSUE();
            }

            // Worse case scenario multiplication: must not overflow in 10 year:
            uint256 result;
            uint256 elem0 = emissionRate * tenYears_ * ACC_REWARD_PRECISION;
            uint256 elem1 = _curve.getFunction(tenYears_);
            unchecked {
                result = elem0 * elem1;
            }
            if (result / elem1 != elem0) revert Reliquary__CURVE_OVERFLOW();

            // totalAllocPoint must never be zero.
            uint256 totalAlloc_ = totalAllocPoint + _allocPoint;
            if (totalAlloc_ == 0) revert Reliquary__ZERO_TOTAL_ALLOC_POINT();
            totalAllocPoint = totalAlloc_;

            //! if _curve is not increasing, allowPartialWithdrawals must be set to false.
            //! We can't check this rule since curve are defined in [0, +infinity].
        }
        // -----------------

        poolInfo.push(
            PoolInfo({
                allocPoint: _allocPoint.toUint96(),
                lastRewardTime: uint40(block.timestamp),
                totalLpSupplied: 0,
                curve: _curve,
                accRewardPerShare: 0,
                name: _name,
                allowPartialWithdrawals: _allowPartialWithdrawals,
                nftDescriptor: _nftDescriptor,
                rewarder: _rewarder,
                poolToken: _poolToken,
                rehypothecation: address(0)
            })
        );

        uint8 newPoolId_ = (poolInfo.length - 1).toUint8();
        if (_rewarder != address(0)) {
            IParentRollingRewarder(_rewarder).initialize(newPoolId_);
        }

        createRelicAndDeposit(_to, newPoolId_, 1);

        emit ReliquaryEvents.LogPoolAddition(
            newPoolId_, _allocPoint, _poolToken, _rewarder, _nftDescriptor, _allowPartialWithdrawals
        );
    }

    /**
     * @notice Modify the given pool's properties. Can only be called by an operator.
     * @param _poolId The index of the pool. See poolInfo.
     * @param _allocPoint New AP of the pool.
     * @param _rewarder Address of the rewarder delegate.
     * @param _name Name of pool to be displayed in NFT image.
     * @param _nftDescriptor The contract address for NFTDescriptor, which will return the token URI.
     * @param _overwriteRewarder True if _rewarder should be set. Otherwise `rewarder` is ignored.
     */
    function modifyPool(
        uint8 _poolId,
        uint256 _allocPoint,
        address _rewarder,
        string calldata _name,
        address _nftDescriptor,
        bool _overwriteRewarder
    ) external whenNotPaused onlyRole(OPERATOR) {
        if (_poolId >= uint8(poolInfo.length)) revert Reliquary__NON_EXISTENT_POOL();

        ReliquaryLogic._massUpdatePools(poolInfo, emissionRate, totalAllocPoint);

        PoolInfo storage pool = poolInfo[_poolId];
        uint256 totalAlloc_ = totalAllocPoint + _allocPoint - uint256(pool.allocPoint);
        if (totalAlloc_ == 0) revert Reliquary__ZERO_TOTAL_ALLOC_POINT();
        totalAllocPoint = totalAlloc_;
        pool.allocPoint = _allocPoint.toUint96();

        if (_overwriteRewarder) {
            pool.rewarder = _rewarder;
            if (_rewarder != address(0)) {
                IParentRollingRewarder(_rewarder).initialize(_poolId);
            }
        }

        pool.name = _name;
        pool.nftDescriptor = _nftDescriptor;

        emit ReliquaryEvents.LogPoolModified(
            _poolId, _allocPoint, _overwriteRewarder ? _rewarder : pool.rewarder, _nftDescriptor
        );
    }

    /**
     * @notice Enable rehypothecation for the given pool. Can only be called by an operator.
     * @param _pid The index of the pool.
     * @param _rehypothecation Address of the rehypothecation contract.
     */
    function enableRehypothecation(uint256 _pid, address _rehypothecation)
        external
        onlyRole(OPERATOR)
    {
        if (treasury == address(0)) revert Reliquary__TREASURY_UNDEFINED();
        ReliquaryRehypothecationLogic._enableRehypothecation(poolInfo[_pid], _rehypothecation);
    }

    /**
     * @notice Disable rehypothecation for the given pool. Can only be called by an operator.
     * @param _pid The index of the pool. See poolInfo.
     * @param _claimRewards Boolean to indicate whether to claim rewards or not.
     */
    function disableRehypothecation(uint256 _pid, bool _claimRewards) external onlyRole(OPERATOR) {
        if (treasury == address(0)) revert Reliquary__TREASURY_UNDEFINED();
        ReliquaryRehypothecationLogic._disableRehypothecation(
            poolInfo[_pid], treasury, _claimRewards
        );
    }

    /**
     * @notice Claim rehypothecation for the given pool.
     *        Can be called by anyone when the contract is not paused.
     * @param _pid The index of the pool. See poolInfo.
     */
    function claimRehypothecation(uint256 _pid) external whenNotPaused {
        if (treasury == address(0)) revert Reliquary__TREASURY_UNDEFINED();
        ReliquaryRehypothecationLogic._claim(poolInfo[_pid], treasury);
    }

    /**
     * @notice Set the address of the treasury. Can only be called by an operator.
     * @param _treasury The new address of the treasury.
     */
    function setTreasury(address _treasury) external onlyRole(OPERATOR) {
        if (_treasury == address(0)) revert Reliquary__ZERO_INPUT();
        treasury = _treasury;
    }

    // -------------- externals --------------

    /**
     * @notice Update reward variables for all pools. Be careful of gas spending!
     */
    function massUpdatePools() external nonReentrant whenNotPaused {
        ReliquaryLogic._massUpdatePools(poolInfo, emissionRate, totalAllocPoint);
    }

    /**
     * @notice Update reward variables of the given pool.
     * @param _poolId The index of the pool. See poolInfo.
     */
    function updatePool(uint8 _poolId) external nonReentrant whenNotPaused {
        ReliquaryLogic._updatePool(poolInfo[_poolId], emissionRate, totalAllocPoint);
    }

    /**
     * @notice Update position without performing a deposit/withdraw.
     *         if _harvestTo != address(0) update and harvest
     *         else just update
     * @param _relicId NFT ID of the position being harvested.
     * @param _harvestTo Address to send rewards to (zero address if harvest should not be performed).
     */
    function update(uint256 _relicId, address _harvestTo) external nonReentrant whenNotPaused {
        if (_harvestTo != address(0)) _requireApprovedOrOwner(_relicId);
        else _requireOwned(_relicId);
        _update(_relicId, _harvestTo);
    }

    /**
     * @notice Deposit pool tokens to Reliquary for reward token allocation.
     *         if _harvestTo != address(0) deposit and harvest
     *         else just deposit
     * @param _amount Token amount to deposit.
     * @param _relicId NFT ID of the position being deposited to.
     * @param _harvestTo Address to send rewards to (zero address if harvest should not be performed).
     */
    function deposit(uint256 _amount, uint256 _relicId, address _harvestTo)
        external
        nonReentrant
        whenNotPaused
    {
        _requireApprovedOrOwner(_relicId);
        _deposit(_amount, _relicId, _harvestTo);
    }

    /**
     * @notice Withdraw pool tokens.
     *         if _harvestTo != address(0) withdraw and harvest
     *         else just withdraw
     * @param _amount token amount to withdraw.
     * @param _relicId NFT ID of the position being withdrawn.
     * @param _harvestTo Address to send rewards to (zero address if harvest should not be performed).
     */
    function withdraw(uint256 _amount, uint256 _relicId, address _harvestTo)
        external
        nonReentrant
        whenNotPaused
    {
        _requireApprovedOrOwner(_relicId);
        _withdraw(_amount, _relicId, _harvestTo);
    }

    /**
     * @notice Withdraw without caring about rewards. EMERGENCY ONLY.
     * @param _relicId NFT ID of the position to emergency withdraw from and burn.
     */
    function emergencyWithdraw(uint256 _relicId) external nonReentrant {
        address to_ = ownerOf(_relicId);
        if (to_ != msg.sender) revert Reliquary__NOT_OWNER();

        PositionInfo storage position = positionForId[_relicId];

        uint256 amount_ = uint256(position.amount);
        uint8 poolId_ = position.poolId;

        PoolInfo storage pool = poolInfo[poolId_];

        ReliquaryLogic._updatePool(pool, emissionRate, totalAllocPoint);

        pool.totalLpSupplied -= amount_ * pool.curve.getFunction(uint256(position.level));

        _burn(_relicId);
        delete positionForId[_relicId];

        ReliquaryRehypothecationLogic._withdraw(pool, amount_);

        IERC20(pool.poolToken).safeTransfer(to_, amount_);

        emit ReliquaryEvents.EmergencyWithdraw(poolId_, amount_, to_, _relicId);
    }

    /**
     * @notice Create a new Relic NFT and deposit into this position.
     * @param _to Address to mint the Relic to.
     * @param _poolId The index of the pool. See poolInfo.
     * @param _amount Token amount to deposit.
     */
    function createRelicAndDeposit(address _to, uint8 _poolId, uint256 _amount)
        public
        nonReentrant
        whenNotPaused
        returns (uint256 relicId_)
    {
        relicId_ = _create(_poolId, _to);
        _deposit(_amount, relicId_, address(0));
    }

    /// @notice Burns the Relic with ID `_relicId`. Cannot be called if there is any principal or rewards in the Relic.
    function burn(uint256 _relicId) public nonReentrant whenNotPaused {
        _requireApprovedOrOwner(_relicId);
        PositionInfo storage position = positionForId[_relicId];
        if (position.amount != 0) revert Reliquary__BURNING_PRINCIPAL();
        if (pendingReward(_relicId) != 0) revert Reliquary__BURNING_REWARDS();

        address rewarder_ = poolInfo[position.poolId].rewarder;

        if (rewarder_ != address(0)) {
            (, uint256[] memory rewardAmounts_) =
                IParentRollingRewarder(rewarder_).pendingTokens(_relicId);

            for (uint256 i = 0; i < rewardAmounts_.length; i++) {
                if (rewardAmounts_[i] != 0) revert Reliquary__BURNING_REWARDS();
            }
        }
        _burn(_relicId);
        delete positionForId[_relicId];
    }

    /**
     * @notice Split an owned Relic into a new one, while maintaining maturity.
     * @param _fromId The NFT ID of the Relic to split from.
     * @param _amount Amount to move from existing Relic into the new one.
     * @param _to Address to mint the Relic to.
     * @return newId_ The NFT ID of the new Relic.
     */
    function split(uint256 _fromId, uint256 _amount, address _to)
        public
        nonReentrant
        whenNotPaused
        returns (uint256 newId_)
    {
        if (_fromId == 1) revert Reliquary__RELIC1_PROHIBITED_ACTION();
        if (_amount == 0) revert Reliquary__ZERO_INPUT();
        _requireApprovedOrOwner(_fromId);

        PositionInfo storage fromPosition = positionForId[_fromId];
        uint8 poolId_ = fromPosition.poolId;
        PoolInfo storage pool = poolInfo[poolId_];
        if (!pool.allowPartialWithdrawals) {
            revert Reliquary__PARTIAL_WITHDRAWALS_DISABLED();
        }

        uint256 fromAmount_ = uint256(fromPosition.amount);
        uint256 newFromAmount_ = fromAmount_ - _amount;
        fromPosition.amount = newFromAmount_.toUint128();

        newId_ = _create(poolId_, _to);
        PositionInfo storage newPosition = positionForId[newId_];
        newPosition.amount = _amount.toUint128();
        newPosition.entry = fromPosition.entry;
        uint256 level_ = uint256(fromPosition.level);
        newPosition.level = uint40(level_);

        uint256 multiplier_ = ReliquaryLogic._updatePool(
            poolInfo[poolId_], emissionRate, totalAllocPoint
        ) * pool.curve.getFunction(level_);
        fromPosition.rewardCredit +=
            Math.mulDiv(fromAmount_, multiplier_, ACC_REWARD_PRECISION) - fromPosition.rewardDebt;

        fromPosition.rewardDebt = Math.mulDiv(newFromAmount_, multiplier_, ACC_REWARD_PRECISION);
        newPosition.rewardDebt = Math.mulDiv(_amount, multiplier_, ACC_REWARD_PRECISION);

        if (pool.rewarder != address(0)) {
            IRewarder(pool.rewarder).onSplit(
                pool.curve, _fromId, newId_, _amount, fromAmount_, level_
            );
        }

        emit ReliquaryEvents.Split(_fromId, newId_, _amount);
    }

    struct LocalVariables_shift {
        uint256 fromAmount;
        uint8 poolId;
        uint256 toAmount;
        uint256 newFromAmount;
        uint256 newToAmount;
        uint256 fromLevel;
        uint256 oldToLevel;
        uint256 newToLevel;
        uint256 accRewardPerShare;
        uint256 fromMultiplier;
        uint256 pendingFrom;
        uint256 pendingTo;
    }

    /**
     * @notice Transfer amount from one Relic into another, updating maturity in the receiving Relic.
     * @param _fromId The NFT ID of the Relic to transfer from.
     * @param _toId The NFT ID of the Relic being transferred to.
     * @param _amount The amount being transferred.
     */
    function shift(uint256 _fromId, uint256 _toId, uint256 _amount)
        public
        nonReentrant
        whenNotPaused
    {
        if (_fromId == 1 || _toId == 1) revert Reliquary__RELIC1_PROHIBITED_ACTION();
        if (_amount == 0) revert Reliquary__ZERO_INPUT();
        if (_fromId == _toId) revert Reliquary__DUPLICATE_RELIC_IDS();
        _requireApprovedOrOwner(_fromId);
        _requireApprovedOrOwner(_toId);

        LocalVariables_shift memory vars_;
        PositionInfo storage fromPosition = positionForId[_fromId];
        vars_.poolId = fromPosition.poolId;
        PoolInfo storage pool = poolInfo[vars_.poolId];

        if (!pool.allowPartialWithdrawals) {
            revert Reliquary__PARTIAL_WITHDRAWALS_DISABLED();
        }

        PositionInfo storage toPosition = positionForId[_toId];
        if (vars_.poolId != toPosition.poolId) revert Reliquary__RELICS_NOT_OF_SAME_POOL();

        vars_.fromAmount = uint256(fromPosition.amount);
        vars_.toAmount = uint256(toPosition.amount);

        vars_.newFromAmount = vars_.fromAmount - _amount;
        fromPosition.amount = vars_.newFromAmount.toUint128();

        vars_.newToAmount = vars_.toAmount + _amount;
        toPosition.amount = vars_.newToAmount.toUint128();

        toPosition.entry = ReliquaryLogic._weightEntry(
            vars_.toAmount, uint256(toPosition.entry), _amount, uint256(fromPosition.entry)
        );

        vars_.fromLevel = positionForId[_fromId].level;
        vars_.oldToLevel = positionForId[_toId].level;
        vars_.newToLevel = ReliquaryLogic._updateLevel(toPosition, vars_.oldToLevel);

        vars_.accRewardPerShare = ReliquaryLogic._updatePool(pool, emissionRate, totalAllocPoint);
        vars_.fromMultiplier = vars_.accRewardPerShare * pool.curve.getFunction(vars_.fromLevel);
        vars_.pendingFrom = Math.mulDiv(
            vars_.fromAmount, vars_.fromMultiplier, ACC_REWARD_PRECISION
        ) - fromPosition.rewardDebt;
        if (vars_.pendingFrom != 0) {
            fromPosition.rewardCredit += vars_.pendingFrom;
        }
        vars_.pendingTo = Math.mulDiv(
            vars_.toAmount,
            vars_.accRewardPerShare * pool.curve.getFunction(vars_.oldToLevel),
            ACC_REWARD_PRECISION
        ) - toPosition.rewardDebt;
        if (vars_.pendingTo != 0) {
            toPosition.rewardCredit += vars_.pendingTo;
        }
        fromPosition.rewardDebt =
            Math.mulDiv(vars_.newFromAmount, vars_.fromMultiplier, ACC_REWARD_PRECISION);
        toPosition.rewardDebt = Math.mulDiv(
            vars_.newToAmount * vars_.accRewardPerShare,
            pool.curve.getFunction(vars_.newToLevel),
            ACC_REWARD_PRECISION
        );

        address rewarder_ = pool.rewarder;
        if (rewarder_ != address(0)) {
            IRewarder(rewarder_).onShift(
                pool.curve,
                _fromId,
                _toId,
                _amount,
                vars_.fromAmount,
                vars_.toAmount,
                vars_.fromLevel,
                vars_.oldToLevel,
                vars_.newToLevel
            );
        }

        ReliquaryLogic._updateTotalLpSuppliedShiftMerge(
            pool,
            vars_.fromLevel,
            vars_.oldToLevel,
            vars_.newToLevel,
            _amount,
            vars_.toAmount,
            vars_.newToAmount
        );

        emit ReliquaryEvents.Shift(_fromId, _toId, _amount);
    }

    /**
     * @notice Transfer entire position (including rewards) from one Relic into another, burning it
     * and updating maturity in the receiving Relic.
     * @param _fromId The NFT ID of the Relic to transfer from.
     * @param _toId The NFT ID of the Relic being transferred to.
     */
    function merge(uint256 _fromId, uint256 _toId) public nonReentrant whenNotPaused {
        if (_fromId == 1 || _toId == 1) revert Reliquary__RELIC1_PROHIBITED_ACTION();
        if (_fromId == _toId) revert Reliquary__DUPLICATE_RELIC_IDS();
        _requireApprovedOrOwner(_fromId);
        _requireApprovedOrOwner(_toId);

        PositionInfo storage fromPosition = positionForId[_fromId];
        uint256 fromAmount_ = uint256(fromPosition.amount);

        uint8 poolId_ = fromPosition.poolId;
        PositionInfo storage toPosition = positionForId[_toId];
        if (poolId_ != toPosition.poolId) revert Reliquary__RELICS_NOT_OF_SAME_POOL();

        PoolInfo storage pool = poolInfo[poolId_];

        uint256 toAmount_ = uint256(toPosition.amount);
        uint256 newToAmount_ = toAmount_ + fromAmount_;
        if (newToAmount_ == 0) revert Reliquary__MERGING_EMPTY_RELICS();

        toPosition.entry = ReliquaryLogic._weightEntry(
            toAmount_, uint256(toPosition.entry), fromAmount_, uint256(fromPosition.entry)
        );

        toPosition.amount = newToAmount_.toUint128();

        uint256 fromLevel_ = uint256(positionForId[_fromId].level);
        uint256 oldToLevel_ = uint256(positionForId[_toId].level);
        uint256 newToLevel_ = ReliquaryLogic._updateLevel(toPosition, oldToLevel_);

        {
            uint256 accRewardPerShare_ =
                ReliquaryLogic._updatePool(poolInfo[poolId_], emissionRate, totalAllocPoint);

            // We split the calculation into two mulDiv()'s to minimise the risk of overflow.
            uint256 pendingTo_ = (
                Math.mulDiv(
                    fromAmount_,
                    accRewardPerShare_ * pool.curve.getFunction(fromLevel_),
                    ACC_REWARD_PRECISION
                )
                    + Math.mulDiv(
                        toAmount_,
                        accRewardPerShare_ * pool.curve.getFunction(oldToLevel_),
                        ACC_REWARD_PRECISION
                    )
            ) + fromPosition.rewardCredit - fromPosition.rewardDebt - toPosition.rewardDebt;

            if (pendingTo_ != 0) {
                toPosition.rewardCredit += pendingTo_;
            }
            toPosition.rewardDebt = Math.mulDiv(
                newToAmount_,
                accRewardPerShare_ * pool.curve.getFunction(newToLevel_),
                ACC_REWARD_PRECISION
            );

            _burn(_fromId);
            delete positionForId[_fromId];
        }

        if (pool.rewarder != address(0)) {
            IRewarder(pool.rewarder).onMerge(
                pool.curve,
                _fromId,
                _toId,
                fromAmount_,
                toAmount_,
                fromLevel_,
                oldToLevel_,
                newToLevel_
            );
        }

        ReliquaryLogic._updateTotalLpSuppliedShiftMerge(
            pool, fromLevel_, oldToLevel_, newToLevel_, fromAmount_, toAmount_, newToAmount_
        );

        emit ReliquaryEvents.Merge(_fromId, _toId, fromAmount_);
    }

    // -------------- internals --------------

    /**
     * @dev Internal deposit function that assumes `relicId` is valid.
     * User needs to ERC20.approve() this contract by `_amount` before using _deposit().
     * @param _amount Amount to deposit.
     * @param _relicId The NFT ID of the position on which the deposit is to be made.
     */
    function _deposit(uint256 _amount, uint256 _relicId, address _harvestTo) internal {
        if (_amount == 0) revert Reliquary__ZERO_INPUT();

        uint8 poolId_ = _updatePosition(_amount, _relicId, Kind.DEPOSIT, _harvestTo);

        PoolInfo storage pool = poolInfo[poolId_];

        IERC20(pool.poolToken).safeTransferFrom(msg.sender, address(this), _amount);
        ReliquaryRehypothecationLogic._deposit(pool);

        emit ReliquaryEvents.Deposit(poolId_, _amount, ownerOf(_relicId), _relicId);
    }

    /**
     * @dev Internal withdraw function that assumes `relicId` is valid.
     * @param _amount Amount to withdraw.
     * @param _relicId The NFT ID of the position on which the withdraw is to be made.
     */
    function _withdraw(uint256 _amount, uint256 _relicId, address _harvestTo) internal {
        if (_amount == 0) revert Reliquary__ZERO_INPUT();

        uint8 poolId_ = _updatePosition(_amount, _relicId, Kind.WITHDRAW, _harvestTo);

        PoolInfo storage pool = poolInfo[poolId_];

        ReliquaryRehypothecationLogic._withdraw(pool, _amount);
        IERC20(pool.poolToken).safeTransfer(msg.sender, _amount);

        emit ReliquaryEvents.Withdraw(poolId_, _amount, msg.sender, _relicId);
    }

    /**
     * @dev Internal update function that assumes `relicId` is valid.
     * @param _relicId The NFT ID of the position on which the withdraw is to be made.
     */
    function _update(uint256 _relicId, address _harvestTo) internal {
        uint8 poolId_ = _updatePosition(0, _relicId, Kind.UPDATE, _harvestTo);

        emit ReliquaryEvents.Update(poolId_, _relicId);
    }

    /**
     * @dev Internal create relic function.
     * @param _poolId The index of the pool.
     * @param _to Address to mint the Relic to.
     * @return relicId_ Relic Id of the newly created position.
     */
    function _create(uint8 _poolId, address _to) internal returns (uint256 relicId_) {
        if (_poolId >= uint8(poolInfo.length)) revert Reliquary__NON_EXISTENT_POOL();

        unchecked {
            relicId_ = ++idNonce;
        }
        _safeMint(_to, relicId_);
        positionForId[relicId_].poolId = _poolId;

        emit ReliquaryEvents.CreateRelic(_poolId, _to, relicId_);
    }
    /**
     * @dev Internal function called whenever a position's state needs to be modified.
     * @param _amount Amount of poolToken to deposit/withdraw.
     * @param _relicId The NFT ID of the position being updated.
     * @param _kind Indicates whether tokens are being added to, or removed from, a pool.
     * @param _harvestTo Address to send rewards to (zero address if harvest should not be performed).
     * @return poolId_ Pool ID of the given position.
     */

    function _updatePosition(uint256 _amount, uint256 _relicId, Kind _kind, address _harvestTo)
        private
        returns (uint8 poolId_)
    {
        PositionInfo storage position = positionForId[_relicId];
        poolId_ = position.poolId;

        uint256 received_ = ReliquaryLogic._updateRelic(
            position,
            poolInfo[poolId_],
            _kind,
            _relicId,
            _amount,
            _harvestTo,
            emissionRate,
            totalAllocPoint,
            rewardToken
        );

        if (_harvestTo != address(0)) {
            emit ReliquaryEvents.Harvest(poolId_, received_, _harvestTo, _relicId);
        }
    }
    // -------------- views --------------

    /// @notice Returns the amount of `poolToken` in Relic#1.
    function getAmountInRelic(uint256 _relicId) external view returns (uint256) {
        return positionForId[_relicId].amount;
    }

    /// @notice Returns a PositionInfo object for the given relicId.
    function getPositionForId(uint256 _relicId)
        external
        view
        returns (PositionInfo memory position_)
    {
        position_ = positionForId[_relicId];
    }

    /// @notice Returns a PoolInfo object for pool ID `_poolId`.
    function getPoolInfo(uint8 _poolId) external view returns (PoolInfo memory pool_) {
        pool_ = poolInfo[_poolId];
    }

    /// @notice This function exists for gas optimization.
    function getTotalLpSupplied(uint8 _poolId) external view returns (uint256 lp_) {
        lp_ = poolInfo[_poolId].totalLpSupplied;
    }
    /// @notice Returns the number of Reliquary pools.

    function poolLength() external view returns (uint256 pools_) {
        pools_ = poolInfo.length;
    }

    /**
     * @notice View function to see pending reward tokens on frontend.
     * @param _relicId ID of the position.
     * @return pending_ reward amount for a given position owner.
     */
    function pendingReward(uint256 _relicId) public view returns (uint256 pending_) {
        PositionInfo storage position = positionForId[_relicId];
        uint8 poolId_ = position.poolId;
        PoolInfo storage pool = poolInfo[poolId_];
        uint256 accRewardPerShare_ = pool.accRewardPerShare;
        uint256 lpSupply_ = pool.totalLpSupplied;
        uint256 secondsSinceReward_ = block.timestamp - uint256(pool.lastRewardTime);

        if (secondsSinceReward_ != 0 && lpSupply_ != 0) {
            uint256 reward_ =
                (secondsSinceReward_ * emissionRate * uint256(pool.allocPoint)) / totalAllocPoint;
            accRewardPerShare_ += Math.mulDiv(reward_, ACC_REWARD_PRECISION, lpSupply_);
        }

        uint256 leveledAmount_ =
            uint256(position.amount) * poolInfo[poolId_].curve.getFunction(position.level);
        pending_ = Math.mulDiv(leveledAmount_, accRewardPerShare_, ACC_REWARD_PRECISION)
            + position.rewardCredit - position.rewardDebt;
    }

    /**
     * @notice Returns the ERC721 tokenURI given by the pool's NFTDescriptor.
     * @dev Can be gas expensive if used in a transaction and the NFTDescriptor is complex.
     * @param _relicId The NFT ID of the Relic to get the tokenURI for.
     */
    function tokenURI(uint256 _relicId) public view override returns (string memory) {
        _requireOwned(_relicId);
        return INFTDescriptor(poolInfo[positionForId[_relicId].poolId].nftDescriptor)
            .constructTokenURI(_relicId);
    }

    /// @dev Implement ERC165 to return which interfaces this contract conforms to
    function supportsInterface(bytes4 _interfaceId)
        public
        view
        override(IERC165, ERC721Enumerable, AccessControlEnumerable)
        returns (bool)
    {
        return _interfaceId == type(IReliquary).interfaceId || super.supportsInterface(_interfaceId);
    }

    /// @notice Returns whether `_spender` is allowed to manage Relic `_relicId`.
    function isApprovedOrOwner(address _spender, uint256 _relicId)
        external
        view
        override
        returns (bool)
    {
        return _isAuthorized(_ownerOf(_relicId), _spender, _relicId);
    }

    /**
     * @notice Require the sender is either the owner of the Relic or approved to transfer it.
     * @param _relicId The NFT ID of the Relic.
     */
    function _requireApprovedOrOwner(uint256 _relicId) private view {
        if (!_isAuthorized(_ownerOf(_relicId), msg.sender, _relicId)) {
            revert Reliquary__NOT_APPROVED_OR_OWNER();
        }
    }
}
