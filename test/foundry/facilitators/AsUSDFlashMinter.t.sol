// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {TestAsUSD} from "test/helpers/TestAsUSD.sol";
import "contracts/facilitators/flash_minter/AsUSDFlashMinter.sol";
import {MockFlashBorrower} from "../../helpers/mocks/MockFlashBorrower.sol";
import "contracts/interfaces/IAsUSDFacilitators.sol";

contract TestAsUSDFlashMinter is TestAsUSD {
    uint256 public constant DEFAULT_FLASH_FEE = 200;
    uint256 public constant DEFAULT_BORROW_AMOUNT = 1000e18;
    uint256 public constant DEFAULT_BUCKET_CAPACITY = 1_000_000e18;

    AsUSDFlashMinter public flashMinter;
    MockFlashBorrower public flashBorrower;

    function setUp() public virtual override {
        super.setUp();
        flashMinter =
            new AsUSDFlashMinter(address(asUSD), treasury, DEFAULT_FLASH_FEE, address(this));
        flashBorrower = new MockFlashBorrower(IERC3156FlashLender(flashMinter));
        asUSD.addFacilitator(address(flashMinter), "Bonjour", uint128(DEFAULT_BUCKET_CAPACITY));
        flashMinter.updateFee(DEFAULT_FLASH_FEE);
    }

    function testConstructor() public {
        vm.expectEmit(true, true, false, false);
        emit AsUSDFlashMinter.TreasurySet(treasury);
        vm.expectEmit(false, false, false, true);
        emit FeeUpdated(0, DEFAULT_FLASH_FEE);
        AsUSDFlashMinter flashMinterTemp =
            new AsUSDFlashMinter(address(asUSD), treasury, DEFAULT_FLASH_FEE, address(this));
        assertEq(address(flashMinterTemp.asUSD()), address(asUSD), "Wrong GHO token address");
        assertEq(flashMinterTemp.getFee(), DEFAULT_FLASH_FEE, "Wrong fee");
        assertEq(flashMinterTemp.getTreasury(), treasury, "Wrong treasury address");
        assertEq(
            address(flashMinterTemp.owner()), address(this), "Wrong addresses provider address"
        );
    }

    function testRevertConstructorFeeOutOfRange() public {
        vm.expectRevert(AsUSDFlashMinter.AsUSDFlashMinter__FEE_OUT_OF_RANGE.selector);
        new AsUSDFlashMinter(address(asUSD), treasury, 10001, address(this));
    }

    function testRevertFlashloanNonRecipient() public {
        vm.expectRevert();
        flashMinter.flashLoan(
            IERC3156FlashBorrower(address(this)), address(asUSD), DEFAULT_BORROW_AMOUNT, ""
        );
    }

    function testRevertFlashloanWrongToken() public {
        vm.expectRevert(AsUSDFlashMinter.AsUSDFlashMinter__UNSUPPORTED_ASSET.selector);
        flashMinter.flashLoan(
            IERC3156FlashBorrower(address(flashBorrower)), address(0), DEFAULT_BORROW_AMOUNT, ""
        );
    }

    function testRevertFlashloanMoreThanCapacity() public {
        vm.expectRevert(IAsUSD.AsUSD__FACILITATOR_BUCKET_CAPACITY_EXCEEDED.selector);
        flashMinter.flashLoan(
            IERC3156FlashBorrower(address(flashBorrower)),
            address(asUSD),
            DEFAULT_BUCKET_CAPACITY + 1,
            ""
        );
    }

    function testRevertFlashloanInsufficientReturned() public {
        vm.expectRevert();
        flashBorrower.flashBorrow(address(asUSD), DEFAULT_BORROW_AMOUNT);
    }

    function testRevertFlashloanWrongCallback() public {
        flashBorrower.setAllowCallback(false);
        vm.expectRevert(AsUSDFlashMinter.AsUSDFlashMinter__CALLBACK_FAILED.selector);
        flashBorrower.flashBorrow(address(asUSD), DEFAULT_BORROW_AMOUNT);
    }

    function testRevertUpdateFeeNotPoolAdmin() public {
        vm.startPrank(userA);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(userA))
        );
        flashMinter.updateFee(100);
    }

    function testRevertUpdateFeeOutOfRange() public {
        vm.expectRevert(AsUSDFlashMinter.AsUSDFlashMinter__FEE_OUT_OF_RANGE.selector);

        flashMinter.updateFee(10001);
    }

    function testRevertUpdateTreasuryNotPoolAdmin() public {
        vm.startPrank(userA);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(userA))
        );
        flashMinter.setTreasury(address(0));
    }

    function testRevertFlashfeeNotGho() public {
        vm.expectRevert(AsUSDFlashMinter.AsUSDFlashMinter__UNSUPPORTED_ASSET.selector);
        flashMinter.flashFee(address(0), DEFAULT_BORROW_AMOUNT);
    }

    /// Positives

    function testFlashloan() public {
        uint256 feeAmount = (DEFAULT_FLASH_FEE * DEFAULT_BORROW_AMOUNT) / 100e2;
        _asUsdFaucet(address(flashBorrower), feeAmount);

        vm.expectEmit(true, true, true, true, address(flashMinter));
        emit FlashMint(
            address(flashBorrower),
            address(flashBorrower),
            address(asUSD),
            DEFAULT_BORROW_AMOUNT,
            feeAmount
        );
        flashBorrower.flashBorrow(address(asUSD), DEFAULT_BORROW_AMOUNT);
    }

    function testDistributeFeesToTreasury() public {
        uint256 treasuryBalanceBefore = asUSD.balanceOf(treasury);

        _asUsdFaucet(address(flashMinter), 100e18);
        assertEq(
            asUSD.balanceOf(address(flashMinter)), 100e18, "GhoFlashMinter should have 100 GHO"
        );

        vm.expectEmit(true, true, false, true, address(flashMinter));
        emit IAsUSDFacilitators.FeesDistributedToTreasury(treasury, address(asUSD), 100e18);
        flashMinter.distributeFeesToTreasury();

        assertEq(
            asUSD.balanceOf(address(flashMinter)),
            0,
            "GhoFlashMinter should have no GHO left after fee distribution"
        );
        assertEq(
            asUSD.balanceOf(treasury),
            treasuryBalanceBefore + 100e18,
            "Treasury should have 100 more GHO"
        );
    }

    function testUpdateFee() public {
        assertEq(flashMinter.getFee(), DEFAULT_FLASH_FEE, "Flashminter non-default fee");
        assertTrue(DEFAULT_FLASH_FEE != 100);
        vm.expectEmit(false, false, false, true, address(flashMinter));
        emit FeeUpdated(DEFAULT_FLASH_FEE, 100);
        flashMinter.updateFee(100);
    }

    function testUpdateGhoTreasury() public {
        assertEq(flashMinter.getTreasury(), treasury, "Flashminter non-default TREASURY");
        assertTrue(treasury != address(this));
        vm.expectEmit(true, true, false, false, address(flashMinter));
        emit AsUSDFlashMinter.TreasurySet(address(this));
        flashMinter.setTreasury(address(this));
    }

    function testMaxFlashloanNotGho() public {
        assertEq(
            flashMinter.maxFlashLoan(address(0)), 0, "Max flash loan should be 0 for non-GHO token"
        );
    }

    function testMaxFlashloanGho() public {
        assertEq(
            flashMinter.maxFlashLoan(address(asUSD)),
            DEFAULT_BUCKET_CAPACITY,
            "Max flash loan should be DEFAULT_BUCKET_CAPACITY for GHO token"
        );
    }

    function testNotWhitelistedFlashFee() public {
        uint256 fee = flashMinter.flashFee(address(asUSD), DEFAULT_BORROW_AMOUNT);
        uint256 expectedFee = (DEFAULT_FLASH_FEE * DEFAULT_BORROW_AMOUNT) / 100e2;
        assertEq(fee, expectedFee, "Flash fee should be correct");
    }

    /// Fuzzing

    function testFuzzFlashFee(uint256 feeToSet, uint256 amount) public {
        vm.assume(feeToSet <= 10000);
        vm.assume(amount <= DEFAULT_BUCKET_CAPACITY);
        flashMinter.updateFee(feeToSet);

        uint256 fee = flashMinter.flashFee(address(asUSD), amount);
        uint256 expectedFee = (feeToSet * amount) / 100e2;

        // We account for +/- 1 wei of rounding error.
        assertTrue(
            fee >= (expectedFee == 0 ? 0 : expectedFee - 1),
            "Flash fee should be greater than or equal to expected fee - 1"
        );
        assertTrue(
            fee <= expectedFee + 1, "Flash fee should be less than or equal to expected fee + 1"
        );
    }

    /// ============ helpers ============

    function _asUsdFaucet(address to, uint256 amt) internal {
        vm.prank(userA);
        asUSD.mint(to, amt);
    }
}
