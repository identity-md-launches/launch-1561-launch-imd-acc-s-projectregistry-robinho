// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryBase} from "./ProjectRegistry.t.sol";
import {ProjectRegistry, IIntake} from "src/ProjectRegistry.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/oracle/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Invalid callbacks must leave both the pending question and every bond untouched.
/// Tests run locally on Sepolia's domain; no RPC or environment mutation is needed.
/// forge-config: default.fuzz.runs = 1000
contract RegistryAdversarialTest is RegistryBase {
    struct Snapshot {
        bytes32 record;
        uint256 held;
        uint256 applicantFunds;
        uint256 challengerFunds;
        uint256 beneficiaryFunds;
        uint256 treasuryFunds;
        uint256 approval;
        uint256 requests;
    }

    function setUp() public override {
        vm.chainId(11155111);
        super.setUp();
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.record = keccak256(abi.encode(reg.projectOf(project)));
        s.held = imd.balanceOf(address(reg));
        s.applicantFunds = imd.balanceOf(applicant);
        s.challengerFunds = imd.balanceOf(challenger);
        s.beneficiaryFunds = imd.balanceOf(beneficiary);
        s.treasuryFunds = imd.balanceOf(intake.TREASURY());
        s.approval = imd.allowance(address(reg), address(intake));
        s.requests = intake.count();
    }

    function _assertUnchanged(Snapshot memory before_) internal view {
        assertEq(
            keccak256(abi.encode(_snapshot())), keccak256(abi.encode(before_)), "atomic rollback"
        );
        bytes32 id = reg.projectOf(project).intakeId;
        if (id != bytes32(0)) assertEq(reg.projectOfIntake(id), project, "pending reverse index");
    }

    function _reject(
        bytes32 id,
        OracleAttestation.Attestation memory a,
        bytes memory signature,
        bytes memory errorData
    ) internal {
        Snapshot memory before_ = _snapshot();
        vm.prank(address(intake));
        vm.expectRevert(errorData);
        reg.onOracleResult(id, a, signature);
        _assertUnchanged(before_);
    }

    function test_everySignedFieldIsAuthenticatedBeforeABondCanMove() public {
        _listed();
        bytes32 id = _challenge();
        // Every iteration starts with a valid message and changes just one signed field.
        for (uint256 field; field < 15; ++field) {
            OracleAttestation.Attestation memory a = _attestation(true);
            bytes memory signature = _sign(a, SIGNER_KEY);
            if (field == 0) a.requestId ^= bytes32(uint256(1));
            else if (field == 1) a.chainId++;
            else if (field == 2) a.questionHash ^= bytes32(uint256(1));
            else if (field == 3) a.answerType++;
            else if (field == 4) a.answer = abi.encode(false);
            else if (field == 5) a.figure++;
            else if (field == 6) a.fromBlock++;
            else if (field == 7) a.toBlock++;
            else if (field == 8) a.blockHash ^= bytes32(uint256(1));
            else if (field == 9) a.panelJobId ^= bytes32(uint256(1));
            else if (field == 10) a.panelSize++;
            else if (field == 11) a.quorum++;
            else if (field == 12) a.agreed++;
            else if (field == 13) a.issuedAt--;
            else a.expiresAt++;
            _reject(
                id,
                a,
                signature,
                abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector)
            );
        }
        assertTrue(_answer(id, false), "invalid attempts did not consume the question");
        assertFalse(reg.isListed(project));
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function test_signatureForSameAddressOnAnotherChainCannotReleaseBond() public {
        _listed();
        bytes32 id = _challenge();
        OracleAttestation.Attestation memory a = _attestation(true);
        vm.chainId(1);
        bytes memory foreignSignature = _sign(a, SIGNER_KEY);
        vm.chainId(11155111);
        _reject(
            id,
            a,
            foreignSignature,
            abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector)
        );
        assertTrue(_answer(id, true));
        assertEq(imd.balanceOf(beneficiary), BOND);
    }

    function test_emptyAndMalformedSignaturesCannotSettle() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        _reject(id, a, "", abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector));
        _reject(
            id,
            a,
            new bytes(64),
            abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector)
        );
        _reject(
            id,
            a,
            new bytes(65),
            abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector)
        );
        _reject(
            id,
            a,
            new bytes(66),
            abi.encodeWithSelector(OracleAttestationConsumer.BadSignature.selector)
        );
        assertTrue(_answer(id, true));
    }

    function testFuzz_shortBoolEncodingCannotReleaseBond(uint8 rawLength) public {
        _listed();
        bytes32 id = _challenge();
        OracleAttestation.Attestation memory a = _attestation(false);
        a.answer = new bytes(bound(rawLength, 0, 31));
        bytes memory signature = _sign(a, SIGNER_KEY);
        Snapshot memory before_ = _snapshot();
        vm.prank(address(intake));
        vm.expectRevert(); // Solidity's ABI decoder rejects an undersized bool word.
        reg.onOracleResult(id, a, signature);
        _assertUnchanged(before_);
    }

    function testFuzz_nonCanonicalBoolCannotDelist(uint256 rawWord) public {
        _listed();
        bytes32 id = _challenge();
        OracleAttestation.Attestation memory a = _attestation(false);
        a.answer = abi.encode(bound(rawWord, 2, type(uint256).max));
        bytes memory signature = _sign(a, SIGNER_KEY);
        Snapshot memory before_ = _snapshot();
        assertFalse(intake.deliver(id, a, signature, 200_000), "non-boolean word accepted");
        _assertUnchanged(before_);
        // The real Intake attempts delivery once. Recovery must not depend on a second answer.
        reg.expire(project);
        assertTrue(reg.isListed(project));
        assertEq(imd.balanceOf(challenger), before_.challengerFunds + BOND);
        assertEq(imd.balanceOf(beneficiary), before_.beneficiaryFunds);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function test_futureIssuedAtToleranceHasExactBoundary() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        a.issuedAt += 301;
        _reject(
            id,
            a,
            _sign(a, SIGNER_KEY),
            abi.encodeWithSelector(
                OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt
            )
        );
        a.issuedAt--;
        assertTrue(intake.deliver(id, a, _sign(a, SIGNER_KEY), 200_000));
        assertTrue(reg.isListed(project));
    }

    function test_answerBeforeAskToleranceHasExactBoundary() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        a.issuedAt -= 301;
        _reject(
            id,
            a,
            _sign(a, SIGNER_KEY),
            abi.encodeWithSelector(ProjectRegistry.AnswerFromBeforeAsk.selector, a.issuedAt)
        );
        a.issuedAt++;
        assertTrue(intake.deliver(id, a, _sign(a, SIGNER_KEY), 200_000));
        assertTrue(reg.isListed(project));
    }

    function test_attestationExpiryIsInclusive() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        a.expiresAt = uint64(block.timestamp - 1);
        _reject(
            id,
            a,
            _sign(a, SIGNER_KEY),
            abi.encodeWithSelector(
                OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt
            )
        );
        a.expiresAt++;
        assertTrue(intake.deliver(id, a, _sign(a, SIGNER_KEY), 200_000));
        assertTrue(reg.isListed(project));
    }

    function testFuzz_pendingDeadlineStillAllowsAnswerButNotExpiry(bool challenge_, bool yes)
        public
    {
        bytes32 id;
        if (challenge_) {
            _listed();
            id = _challenge();
        } else {
            id = _apply();
        }
        vm.warp(uint256(reg.projectOf(project).askedAt) + 1 days);
        Snapshot memory before_ = _snapshot();
        vm.expectRevert(ProjectRegistry.NotStale.selector);
        reg.expire(project);
        _assertUnchanged(before_);
        assertTrue(_answer(id, yes), "answer at exact deadline");
        assertEq(reg.isListed(project), yes);
        assertEq(reg.projectOfIntake(id), address(0));
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function test_oneSecondAfterDeadlineCannotReleaseBondToBeneficiary() public {
        _listed();
        bytes32 id = _challenge();
        vm.warp(uint256(reg.projectOf(project).askedAt) + 1 days + 1);
        OracleAttestation.Attestation memory a = _attestation(true);
        _reject(
            id, a, _sign(a, SIGNER_KEY), abi.encodeWithSelector(ProjectRegistry.TooLate.selector)
        );
        vm.prank(makeAddr("unrelated expirer"));
        reg.expire(project);
        assertTrue(reg.isListed(project));
        assertEq(imd.balanceOf(challenger), 1_000e18 - 0.5e18);
        assertEq(imd.balanceOf(beneficiary), 0);
        vm.expectRevert(ProjectRegistry.NothingToExpire.selector);
        reg.expire(project);
    }

    function test_challengeCooldownHasExactBoundary() public {
        _listed();
        uint64 openAt = reg.projectOf(project).challengeOpenAt;
        vm.warp(openAt - 1);
        Snapshot memory before_ = _snapshot();
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.ChallengeTooSoon.selector, openAt));
        reg.challenge(project, "Check the fee distribution.");
        _assertUnchanged(before_);
        vm.warp(openAt);
        vm.prank(challenger);
        bytes32 id = reg.challenge(project, "Check the fee distribution.");
        assertEq(reg.projectOfIntake(id), project);
        assertEq(imd.balanceOf(address(reg)), BOND);
    }

    function test_thirdPartyPaidQuestionCannotListOurProject() public {
        bytes32 ownId = _apply();
        vm.startPrank(challenger);
        imd.approve(address(intake), 0.5e18);
        bytes32 foreignId = intake.requestWithFailure(
            bytes32("oracle.request@oracle-1"),
            bytes("{}"),
            IIntake.Callback(address(reg), reg.onOracleResult.selector),
            reg.onOracleFailure.selector,
            address(imd),
            0.5e18
        );
        vm.stopPrank();
        OracleAttestation.Attestation memory a = _attestation(true);
        Snapshot memory before_ = _snapshot();
        assertFalse(intake.deliver(foreignId, a, _sign(a, SIGNER_KEY), 200_000));
        assertFalse(intake.fail(foreignId, 1, "body_invalid", 200_000));
        _assertUnchanged(before_);
        assertEq(reg.projectOfIntake(foreignId), address(0));
        assertTrue(_answer(ownId, true));
    }

    function testFuzz_oldCallbacksCannotCloseReplacementApplication(uint8 rawEnd) public {
        bytes32 oldId = _apply();
        uint256 ending = bound(rawEnd, 0, 3);
        if (ending == 0) {
            assertTrue(_answer(oldId, false));
        } else if (ending == 1) {
            assertTrue(intake.fail(oldId, 1, "body_refused", 200_000));
        } else if (ending == 2) {
            vm.warp(block.timestamp + 1 days + 1);
            reg.expire(project);
        } else {
            intake.completeSilently(oldId);
            reg.expire(project);
        }
        bytes32 newId = _apply();
        assertNotEq(newId, oldId);
        _assertOldCallbacksRefused(oldId);
        assertEq(reg.projectOfIntake(newId), project);
        assertTrue(_answer(newId, true));
    }

    function test_oldChallengeCannotRefundTwiceOrCloseNewChallenge() public {
        _listed();
        bytes32 oldId = _challenge();
        assertTrue(_answer(oldId, true));
        bytes32 newId = _challenge();
        _assertOldCallbacksRefused(oldId);
        assertTrue(_answer(newId, false));
        assertEq(imd.balanceOf(beneficiary), BOND, "exactly one defended bond");
        assertEq(imd.balanceOf(challenger), 1_000e18 - 1e18 - BOND);
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function _assertOldCallbacksRefused(bytes32 oldId) internal {
        OracleAttestation.Attestation memory a = _attestation(true);
        _reject(
            oldId,
            a,
            _sign(a, SIGNER_KEY),
            abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, oldId)
        );
        Snapshot memory before_ = _snapshot();
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, oldId));
        reg.onOracleFailure(oldId, 2, "disagreed", 0, 0, "");
        _assertUnchanged(before_);
    }

    function test_starvedChallengeCallbackRefundsOnlyChallenger() public {
        _listed();
        bytes32 id = _challenge();
        OracleAttestation.Attestation memory a = _attestation(true);
        Snapshot memory before_ = _snapshot();
        assertFalse(intake.deliver(id, a, _sign(a, SIGNER_KEY), 5_000));
        _assertUnchanged(before_);
        vm.prank(applicant);
        reg.expire(project);
        assertEq(imd.balanceOf(challenger), before_.challengerFunds + BOND);
        assertEq(imd.balanceOf(beneficiary), before_.beneficiaryFunds);
        assertTrue(reg.isListed(project));
        vm.expectRevert(ProjectRegistry.NothingToExpire.selector);
        reg.expire(project);
    }

    function test_beneficiaryHandoverWaitsForSettlementAndRevokesOldWallet() public {
        _listed();
        bytes32 id = _challenge();
        address next = makeAddr("new beneficiary");
        Snapshot memory before_ = _snapshot();
        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.setBeneficiary(project, next);
        _assertUnchanged(before_);
        assertTrue(_answer(id, true));
        assertEq(imd.balanceOf(beneficiary), BOND, "challenged beneficiary receives the bond");
        assertEq(imd.balanceOf(next), 0);

        vm.prank(beneficiary);
        reg.setBeneficiary(project, next);
        assertTrue(reg.beneficiaryPinRequired(project));
        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.NotBeneficiary.selector);
        reg.setBeneficiary(project, beneficiary);
        assertEq(reg.projectOf(project).beneficiary, next);

        vm.prank(challenger);
        id = reg.challengeForBeneficiary(project, "Review the new beneficiary.", next);
        assertTrue(_answer(id, true));
        assertEq(imd.balanceOf(next), BOND);
        assertEq(imd.balanceOf(beneficiary), BOND, "handoff cannot redirect an earlier bond");
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function test_intakeRevertRollsBackFeeBondApprovalAndOpenRecord() public {
        _listed();
        vm.warp(block.timestamp + COOLDOWN);
        Snapshot memory before_ = _snapshot();
        bytes memory errorData = abi.encodeWithSignature("IntakeUnavailable()");
        vm.mockCallRevert(address(intake), IIntake.requestWithFailure.selector, errorData);
        vm.prank(challenger);
        vm.expectRevert(errorData);
        reg.challenge(project, "Review the project.");
        _assertUnchanged(before_);
        vm.clearMockedCalls();
        bytes32 id = _challenge();
        assertTrue(_answer(id, false), "guard recovered after failed external call");
    }

    function test_tokenReturningFalseCannotCreatePaidRequest() public {
        Snapshot memory before_ = _snapshot();
        vm.mockCall(
            address(imd), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(false)
        );
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd))
        );
        _apply();
        _assertUnchanged(before_);
        vm.clearMockedCalls();
        assertTrue(_answer(_apply(), true));
    }

    function test_challengeShortAllowanceCannotBorrowDonatedFunds() public {
        _listed();
        imd.mint(address(reg), 100e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(challenger);
        imd.approve(address(reg), BOND + 0.5e18 - 1);
        Snapshot memory before_ = _snapshot();
        vm.prank(challenger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(reg),
                BOND + 0.5e18 - 1,
                BOND + 0.5e18
            )
        );
        reg.challenge(project, "Review the project.");
        _assertUnchanged(before_);
    }

    function test_maximumFeeAdditionRevertsWithoutChangingListing() public {
        _listed();
        vm.warp(block.timestamp + COOLDOWN);
        intake.setPrice(type(uint256).max);
        Snapshot memory before_ = _snapshot();
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        reg.challenge(project, "Review the project.");
        _assertUnchanged(before_);
    }
}
