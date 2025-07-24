// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

/// LayerZero
// Mock imports
import {OFTMock} from "../../helpers/mocks/OFTMock.sol";
import {ERC20Mock} from "../../helpers/mocks/ERC20Mock.sol";
import {OFTComposerMock} from "../../helpers/mocks/OFTComposerMock.sol";
import {IOFTExtended} from "contracts/interfaces/IOFTExtended.sol";

// OApp imports
import {
    IOAppOptionsType3,
    EnforcedOptionParam
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OAppOptionsType3.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

// OFT imports
import {
    IOFT,
    SendParam,
    OFTReceipt
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {
    MessagingFee, MessagingReceipt
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTCore.sol";
import {OFTMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTMsgCodec.sol";
import {OFTComposeMsgCodec} from
    "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";

/// Main import
import "@openzeppelin/contracts/utils/Strings.sol";
import "contracts/tokens/AsUSD.sol";
import "contracts/interfaces/IAsUSD.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "test/helpers/Events.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {TestAsUSD} from "test/helpers/TestAsUSD.sol";

contract TestBaseAsUSD is TestAsUSD {
    uint128 public initialBalance = 100 ether;

    function setUp() public virtual override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);

        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        asUSD = AsUSD(
            _deployOApp(
                type(AsUSD).creationCode,
                abi.encode("aOFT", "aOFT", address(endpoints[aEid]), owner, treasury, guardian)
            )
        );

        asUSD.addFacilitator(userA, "user a", initialBalance);
    }

    function testNameSymbolUpdate() public {
        assertEq(asUSD.name(), "aOFT");
        assertEq(asUSD.symbol(), "aOFT");

        asUSD.setName("NNN");
        asUSD.setSymbol("SSS");

        assertEq(asUSD.name(), "NNN");
        assertEq(asUSD.symbol(), "SSS");

        vm.startPrank(address(0xdead000));
        vm.expectRevert();
        asUSD.setName("NNN");

        vm.expectRevert();
        asUSD.setSymbol("SSS");

        vm.stopPrank();
    }

    function testGetFacilitatorData() public {
        IAsUSD.Facilitator memory data = asUSD.getFacilitator(userA);
        assertEq(data.label, "user a", "Unexpected facilitator label");
        assertEq(data.bucketCapacity, initialBalance, "Unexpected bucket capacity");
        assertEq(data.bucketLevel, 0, "Unexpected bucket level");
    }

    function testGetNonFacilitatorData() public {
        IAsUSD.Facilitator memory data = asUSD.getFacilitator(userB);
        assertEq(data.label, "", "Unexpected facilitator label");
        assertEq(data.bucketCapacity, 0, "Unexpected bucket capacity");
        assertEq(data.bucketLevel, 0, "Unexpected bucket level");
    }

    function testGetFacilitatorBucket() public {
        (uint256 capacity, uint256 level) = asUSD.getFacilitatorBucket(userA);
        assertEq(capacity, initialBalance, "Unexpected bucket capacity");
        assertEq(level, 0, "Unexpected bucket level");
    }

    function testGetNonFacilitatorBucket() public {
        (uint256 capacity, uint256 level) = asUSD.getFacilitatorBucket(userB);
        assertEq(capacity, 0, "Unexpected bucket capacity");
        assertEq(level, 0, "Unexpected bucket level");
    }

    function testGetPopulatedFacilitatorsList() public {
        asUSD.addFacilitator(userB, "user b", initialBalance);

        address[] memory facilitatorList = asUSD.getFacilitatorsList();
        assertEq(facilitatorList.length, 2, "Unexpected number of facilitators");
        assertEq(facilitatorList[0], userA, "Unexpected address for mock facilitator 1");
        assertEq(facilitatorList[1], userB, "Unexpected address for mock facilitator 2");
    }

    function testAddFacilitator() public {
        vm.expectEmit(true, true, false, true, address(asUSD));
        emit FacilitatorAdded(userC, keccak256(abi.encodePacked("Alice")), initialBalance);
        asUSD.addFacilitator(userC, "Alice", initialBalance);
    }

    function testRevertAddExistingFacilitator() public {
        vm.expectRevert(IAsUSD.AsUSD__FACILITATOR_ALREADY_EXISTS.selector);
        asUSD.addFacilitator(userA, "Astera Pool", initialBalance);
    }

    function testRevertAddFacilitatorNoLabel() public {
        vm.expectRevert(IAsUSD.AsUSD__INVALID_LABEL.selector);
        asUSD.addFacilitator(userB, "", initialBalance);
    }

    function testRevertAddFacilitatorNoRole() public {
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        asUSD.addFacilitator(userA, "Alice", initialBalance);
    }

    function testRevertSetBucketCapacityNonFacilitator() public {
        vm.expectRevert(IAsUSD.AsUSD__FACILITATOR_DOES_NOT_EXIST.selector);

        asUSD.setFacilitatorBucketCapacity(userB, initialBalance);
    }

    function testSetNewBucketCapacity() public {
        vm.expectEmit(true, false, false, true, address(asUSD));
        emit FacilitatorBucketCapacityUpdated(userA, initialBalance, 0);
        asUSD.setFacilitatorBucketCapacity(userA, 0);
    }

    function testSetNewBucketCapacityAsManager() public {
        asUSD.transferOwnership(userB);
        vm.prank(userB);
        vm.expectEmit(true, false, false, true, address(asUSD));
        emit FacilitatorBucketCapacityUpdated(userA, initialBalance, 0);
        asUSD.setFacilitatorBucketCapacity(userA, 0);

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        asUSD.setFacilitatorBucketCapacity(userA, 0);
    }

    function testRevertSetNewBucketCapacityNoRole() public {
        vm.prank(userB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userB));
        asUSD.setFacilitatorBucketCapacity(userA, 0);
    }

    function testRevertRemoveNonFacilitator() public {
        vm.expectRevert(IAsUSD.AsUSD__FACILITATOR_DOES_NOT_EXIST.selector);
        asUSD.removeFacilitator(userB);
    }

    function testRevertRemoveFacilitatorNonZeroBucket() public {
        vm.prank(userA);
        asUSD.mint(userA, 1);

        vm.expectRevert(IAsUSD.AsUSD__FACILITATOR_BUCKET_LEVEL_NOT_ZERO.selector);
        asUSD.removeFacilitator(userA);
    }

    function testRemoveFacilitator() public {
        vm.expectEmit(true, false, false, true, address(asUSD));
        emit FacilitatorRemoved(userA);
        asUSD.removeFacilitator(userA);
    }

    function testRevertRemoveFacilitatorNoRole() public {
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
        asUSD.removeFacilitator(userA);
    }

    function testRevertMintBadFacilitator() public {
        vm.prank(userB);
        vm.expectRevert(IAsUSD.AsUSD__FACILITATOR_BUCKET_CAPACITY_EXCEEDED.selector);
        asUSD.mint(userA, 1);
    }

    function testRevertMintExceedCapacity() public {
        vm.prank(userA);
        vm.expectRevert(IAsUSD.AsUSD__FACILITATOR_BUCKET_CAPACITY_EXCEEDED.selector);
        asUSD.mint(userA, initialBalance + 1);
    }

    function testMint() public {
        vm.prank(userA);
        vm.expectEmit(true, true, false, true, address(asUSD));
        emit Transfer(address(0), userB, initialBalance);
        vm.expectEmit(true, false, false, true, address(asUSD));
        emit FacilitatorBucketLevelUpdated(userA, 0, initialBalance);
        asUSD.mint(userB, initialBalance);
    }

    function testRevertZeroMint() public {
        vm.prank(userA);
        vm.expectRevert(IAsUSD.AsUSD__INVALID_MINT_AMOUNT.selector);
        asUSD.mint(userB, 0);
    }

    function testRevertZeroBurn() public {
        vm.prank(userA);
        vm.expectRevert(IAsUSD.AsUSD__INVALID_BURN_AMOUNT.selector);
        asUSD.burn(0);
    }

    function testRevertBurnMoreThanMinted() public {
        vm.prank(userA);
        vm.expectEmit(true, false, false, true, address(asUSD));
        emit FacilitatorBucketLevelUpdated(userA, 0, initialBalance);
        asUSD.mint(userA, initialBalance);

        vm.prank(userA);
        vm.expectRevert();
        asUSD.burn(initialBalance + 1);
    }

    function testRevertBurnOthersTokens() public {
        vm.prank(userA);
        vm.expectEmit(true, true, false, true, address(asUSD));
        emit Transfer(address(0), userB, initialBalance);
        vm.expectEmit(true, false, false, true, address(asUSD));
        emit FacilitatorBucketLevelUpdated(userA, 0, initialBalance);
        asUSD.mint(userB, initialBalance);

        vm.prank(userA);
        vm.expectRevert();
        asUSD.burn(initialBalance);
    }

    function testBurn() public {
        vm.prank(userA);
        vm.expectEmit(true, true, false, true, address(asUSD));
        emit Transfer(address(0), userA, initialBalance);
        vm.expectEmit(true, false, false, true, address(asUSD));
        emit FacilitatorBucketLevelUpdated(userA, 0, initialBalance);
        asUSD.mint(userA, initialBalance);

        // vm.prank(userA);
        // vm.expectEmit(true, false, false, true, address(asUSD));
        // emit FacilitatorBucketLevelUpdated(userA, initialBalance, initialBalance - 1000);
        // asUSD.burn(1000);
    }

    function testOffboardFacilitator() public {
        // Onboard facilitator
        vm.expectEmit(true, true, false, true, address(asUSD));
        emit FacilitatorAdded(userB, keccak256(abi.encodePacked("Alice")), initialBalance);
        asUSD.addFacilitator(userB, "Alice", initialBalance);

        // Facilitator mints half of its capacity
        vm.prank(userB);
        asUSD.mint(userB, initialBalance / 2);
        (uint256 bucketCapacity, uint256 bucketLevel) = asUSD.getFacilitatorBucket(userB);
        assertEq(bucketCapacity, initialBalance, "Unexpected bucket capacity of facilitator");
        assertEq(bucketLevel, initialBalance / 2, "Unexpected bucket level of facilitator");

        // Facilitator cannot be removed
        vm.expectRevert(IAsUSD.AsUSD__FACILITATOR_BUCKET_LEVEL_NOT_ZERO.selector);
        asUSD.removeFacilitator(userB);

        // Facilitator Bucket Capacity set to 0
        asUSD.setFacilitatorBucketCapacity(userB, 0);

        // Facilitator cannot mint more and is expected to burn remaining level
        vm.prank(userB);
        vm.expectRevert(IAsUSD.AsUSD__FACILITATOR_BUCKET_CAPACITY_EXCEEDED.selector);
        asUSD.mint(userB, 1);

        vm.prank(userB);
        asUSD.burn(bucketLevel);

        // Facilitator can be removed with 0 bucket level
        vm.expectEmit(true, false, false, true, address(asUSD));
        emit FacilitatorRemoved(address(userB));
        asUSD.removeFacilitator(address(userB));
    }

    function testDomainSeparator() public {
        bytes32 EIP712_DOMAIN = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes memory EIP712_REVISION = bytes("1");
        bytes32 expected = keccak256(
            abi.encode(
                EIP712_DOMAIN,
                keccak256(bytes(asUSD.name())),
                keccak256(EIP712_REVISION),
                block.chainid,
                address(asUSD)
            )
        );
        bytes32 result = asUSD.DOMAIN_SEPARATOR();
        assertEq(result, expected, "Unexpected domain separator");
    }

    function testDomainSeparatorNewChain() public {
        vm.chainId(31338);
        bytes32 EIP712_DOMAIN = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes memory EIP712_REVISION = bytes("1");
        bytes32 expected = keccak256(
            abi.encode(
                EIP712_DOMAIN,
                keccak256(bytes(asUSD.name())),
                keccak256(EIP712_REVISION),
                block.chainid,
                address(asUSD)
            )
        );
        bytes32 result = asUSD.DOMAIN_SEPARATOR();
        assertEq(result, expected, "Unexpected domain separator");
    }

    function testPermitAndVerifyNonce() public {
        (address david, uint256 davidKey) = makeAddrAndKey("david");
        vm.prank(userA);
        asUSD.mint(david, 1e18);
        bytes32 PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
        bytes32 innerHash = keccak256(abi.encode(PERMIT_TYPEHASH, david, userC, 1e18, 0, 1 hours));
        bytes32 outerHash =
            keccak256(abi.encodePacked("\x19\x01", asUSD.DOMAIN_SEPARATOR(), innerHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(davidKey, outerHash);
        asUSD.permit(david, userC, 1e18, 1 hours, v, r, s);

        assertEq(asUSD.allowance(david, userC), 1e18, "Unexpected allowance");
        assertEq(asUSD.nonces(david), 1, "Unexpected nonce");
    }

    function testRevertPermitInvalidSignature() public {
        (address david, uint256 davidKey) = makeAddrAndKey("david");
        bytes32 PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
        bytes32 innerHash = keccak256(abi.encode(PERMIT_TYPEHASH, userB, userC, 1e18, 0, 1 hours));
        bytes32 outerHash =
            keccak256(abi.encodePacked("\x19\x01", asUSD.DOMAIN_SEPARATOR(), innerHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(davidKey, outerHash);

        vm.expectRevert(
            abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, david, userB)
        );
        asUSD.permit(userB, userC, 1e18, 1 hours, v, r, s);
    }

    function testRevertPermitInvalidDeadline() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20Permit.ERC2612ExpiredSignature.selector, block.timestamp - 1
            )
        );
        asUSD.permit(userB, userC, 1e18, block.timestamp - 1, 0, 0, 0);
    }
}
