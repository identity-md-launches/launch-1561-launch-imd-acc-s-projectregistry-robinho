// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/oracle/OracleAttestation.sol";
import {MockIntake, MintableIMD, MockProject} from "./mocks/MockIntake.sol";

/// @notice Protocol constants/vector copied verbatim from the supplied oracle-consumer reference.
/// ProjectRegistry requires bool and a 15/11 panel, so the unmodified bytes32[] vector verifies
/// its signature then fails the policy check. A fresh bool signed by the same vector key settles.
contract OracleConsumerConformanceTest is Test {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST =
        0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY =
        0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    /// @dev The callback's canonical signature. Its selector is what the intake calls: a struct that
    /// differs from the protocol's by one field has another selector and is never reached.
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    MockIntake intake;
    MintableIMD asset;
    ProjectRegistry consumer;
    address project;
    bytes32 intakeId;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        vm.roll(300);
        intake = new MockIntake();
        asset = new MintableIMD();
        deployConsumer();
        project = address(new MockProject());
        asset.mint(address(this), 1e18);
        asset.approve(address(consumer), 1e18);
        intakeId = consumer.applyListing(
            project, "Vector", "https://example.org/source", 50, address(this)
        );
    }

    function deployConsumer() internal {
        deployCodeTo(
            "ProjectRegistry.sol:ProjectRegistry",
            abi.encode(
                caller(),
                address(asset),
                address(new MockProject()),
                SIGNER,
                uint256(1),
                uint256(5e18),
                uint64(3600)
            ),
            VECTOR_CONSUMER
        );
        consumer = ProjectRegistry(VECTOR_CONSUMER);
    }

    function caller() internal view returns (address) {
        return address(intake);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function test_digestMatchesTheProtocol() public view {
        assertEq(
            consumer.attestationDigest(vector()),
            VECTOR_DIGEST,
            "struct, type string or domain differs from the protocol"
        );
    }

    function test_callbackSelectorIsCanonical() public view {
        assertEq(consumer.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
        assertEq(consumer.onOracleResult.selector, bytes4(0x510379c7));
    }

    function test_protocolSignaturePassesVerificationBeforePanelPolicy() public {
        vm.prank(caller());
        vm.expectRevert(ProjectRegistry.WrongPanel.selector);
        consumer.onOracleResult(intakeId, vector(), VECTOR_SIGNATURE);
        assertFalse(consumer.isListed(project));
    }

    function test_tamperingTheProtocolVectorFailsSignatureVerification() public {
        OracleAttestation.Attestation memory a = vector();
        a.figure++;
        vm.prank(caller());
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        consumer.onOracleResult(intakeId, a, VECTOR_SIGNATURE);
    }

    function test_acceptsAFreshSignatureFromTheVectorKey() public {
        OracleAttestation.Attestation memory a = vector();
        a.requestId = keccak256("another request");
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(true);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 11;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        assertTrue(intake.deliver(intakeId, a, abi.encodePacked(r, s, v), 200_000));
        assertTrue(consumer.isListed(project));
        assertEq(consumer.projectOfIntake(intakeId), address(0), "intake ID consumed exactly once");
        vm.prank(caller());
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, intakeId));
        consumer.onOracleResult(intakeId, a, abi.encodePacked(r, s, v));
    }
}
