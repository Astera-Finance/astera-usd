// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {PercentageMath} from "lib/astera/contracts/protocol/libraries/math/PercentageMath.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IAsUSD} from "contracts/interfaces/IAsUSD.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAsUSDFacilitators} from "contracts/interfaces/IAsUSDFacilitators.sol";
import {Errors} from "lib/astera/contracts/protocol/libraries/helpers/Errors.sol";

/**
 * @title A contract enabling flash minting of AsUSD tokens.
 * @author Conclave - Beirao
 * @notice Allows users to flash mint AsUSD tokens by implementing EIP-3156.
 * @dev Based on EIP-3156 reference implementation and Aave's GHO flash minter.
 */
contract AsUSDFlashMinter is IAsUSDFacilitators, IERC3156FlashLender, Ownable {
    using PercentageMath for uint256;

    /// @dev Expected return value from a successful flash loan callback as keccak256 hash.
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @dev Maximum fee settable in basis points (10000 = 100%).
    uint256 public constant MAX_FEE = 1e4;

    /// @dev Reference to the AsUSD token contract.
    IAsUSD public immutable asUSD;

    /// @dev Flash mint fee in basis points (10000 = 100%).
    uint256 private fee;

    /// @dev Address receiving collected flash mint fees.
    address private treasury;

    /// @dev Thrown when fee exceeds MAX_FEE.
    error AsUSDFlashMinter__FEE_OUT_OF_RANGE();
    /// @dev Thrown when flash loan requested for unsupported token.
    error AsUSDFlashMinter__UNSUPPORTED_ASSET();
    /// @dev Thrown when flash loan callback returns unexpected value.
    error AsUSDFlashMinter__CALLBACK_FAILED();

    /**
     * @dev Emitted on successful flash mint.
     * @param receiver Address receiving flash minted tokens.
     * @param initiator Address initiating flash mint.
     * @param asset Address of flash minted token.
     * @param amount Number of tokens flash minted.
     * @param fee Fee charged for flash mint.
     */
    event FlashMint(
        address indexed receiver,
        address indexed initiator,
        address asset,
        uint256 indexed amount,
        uint256 fee
    );

    /**
     * @dev Emitted when flash mint fee changes.
     * @param oldFee Previous fee in basis points.
     * @param newFee New fee in basis points.
     */
    event FeeUpdated(uint256 oldFee, uint256 newFee);

    /**
     * @dev Emitted when treasury address changes.
     * @param treasury New treasury address.
     */
    event TreasurySet(address indexed treasury);

    /**
     * @notice Sets up initial flash minting configuration.
     * @dev Validates fee and initializes contract state.
     * @param _asUsdToken Address of AsUSD token contract.
     * @param _treasury Address receiving flash mint fees.
     * @param _fee Initial flash mint fee in basis points.
     * @param _admin Address with admin privileges.
     */
    constructor(address _asUsdToken, address _treasury, uint256 _fee, address _admin)
        Ownable(_admin)
    {
        if (_fee > MAX_FEE) revert AsUSDFlashMinter__FEE_OUT_OF_RANGE();
        asUSD = IAsUSD(_asUsdToken);
        _setTreasury(_treasury);
        _updateFee(_fee);
    }

    /**
     * @notice Executes a flash loan of AsUSD tokens.
     * @dev Mints tokens, calls receiver callback, verifies repayment, burns principal.
     * @param _receiver Contract receiving flash loan.
     * @param _token Address of token to flash loan.
     * @param _amount Number of tokens to flash loan.
     * @param _data Arbitrary data passed to receiver.
     * @return true if flash loan succeeds.
     */
    function flashLoan(
        IERC3156FlashBorrower _receiver,
        address _token,
        uint256 _amount,
        bytes calldata _data
    ) external returns (bool) {
        if (_token != address(asUSD)) revert AsUSDFlashMinter__UNSUPPORTED_ASSET();

        uint256 fee_ = _flashFee(_amount);
        asUSD.mint(address(_receiver), _amount);

        if (
            _receiver.onFlashLoan(msg.sender, address(asUSD), _amount, fee_, _data)
                != CALLBACK_SUCCESS
        ) revert AsUSDFlashMinter__CALLBACK_FAILED();

        asUSD.transferFrom(address(_receiver), address(this), _amount + fee_);
        asUSD.burn(_amount);

        emit FlashMint(address(_receiver), msg.sender, address(asUSD), _amount, fee_);

        return true;
    }

    /**
     * @notice Transfers accumulated flash mint fees to treasury.
     * @dev Sends entire AsUSD balance to treasury address.
     */
    function distributeFeesToTreasury() external {
        uint256 balance_ = asUSD.balanceOf(address(this));
        asUSD.transfer(treasury, balance_);
        emit FeesDistributedToTreasury(treasury, address(asUSD), balance_);
    }

    /**
     * @notice Changes the flash mint fee.
     * @dev Only owner can call. Fee must not exceed MAX_FEE.
     * @param _newFee New fee in basis points.
     */
    function updateFee(uint256 _newFee) external onlyOwner {
        _updateFee(_newFee);
    }

    /**
     * @notice Changes the treasury address.
     * @dev Only owner can call. New treasury cannot be zero address.
     * @param _newTreasury New treasury address.
     */
    function setTreasury(address _newTreasury) external onlyOwner {
        _setTreasury(_newTreasury);
    }

    /**
     * @notice Gets maximum possible flash loan amount.
     * @dev Returns remaining capacity for this facilitator.
     * @param _token Address of token to check.
     * @return Maximum available flash loan amount.
     */
    function maxFlashLoan(address _token) external view returns (uint256) {
        if (_token != address(asUSD)) {
            return 0;
        } else {
            (uint256 capacity_, uint256 level_) = asUSD.getFacilitatorBucket(address(this));
            return capacity_ > level_ ? capacity_ - level_ : 0;
        }
    }

    /**
     * @notice Calculates fee for a flash loan amount.
     * @dev Returns zero for unsupported tokens.
     * @param _token Address of token for fee calculation.
     * @param _amount Number of tokens for fee calculation.
     * @return Fee amount in tokens.
     */
    function flashFee(address _token, uint256 _amount) external view returns (uint256) {
        if (_token != address(asUSD)) revert AsUSDFlashMinter__UNSUPPORTED_ASSET();
        return _flashFee(_amount);
    }

    /**
     * @notice Gets current flash mint fee.
     * @return Current fee in basis points.
     */
    function getFee() external view returns (uint256) {
        return fee;
    }

    /**
     * @notice Gets current treasury address.
     * @return Address of treasury.
     */
    function getTreasury() external view returns (address) {
        return treasury;
    }

    /**
     * @dev Calculates fee amount for given principal.
     * @param _amount Principal amount for fee calculation.
     * @return Fee amount in tokens.
     */
    function _flashFee(uint256 _amount) internal view returns (uint256) {
        return _amount.percentMul(fee);
    }

    /**
     * @dev Updates flash mint fee after validation.
     * @param _newFee New fee in basis points.
     */
    function _updateFee(uint256 _newFee) internal {
        if (_newFee > MAX_FEE) revert AsUSDFlashMinter__FEE_OUT_OF_RANGE();
        uint256 oldFee_ = fee;
        fee = _newFee;
        emit FeeUpdated(oldFee_, _newFee);
    }

    /**
     * @dev Updates treasury address after validation.
     * @param _treasury New treasury address.
     */
    function _setTreasury(address _treasury) internal {
        require(_treasury != address(0), Errors.AT_INVALID_ADDRESS);
        treasury = _treasury;

        emit TreasurySet(_treasury);
    }
}
