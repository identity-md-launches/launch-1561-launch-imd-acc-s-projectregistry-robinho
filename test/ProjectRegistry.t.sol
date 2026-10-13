// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/oracle/OracleAttestation.sol";
import {MockIntake, MintableIMD, MockProject} from "./mocks/MockIntake.sol";

/// @dev Shared fixture: a registry wired to a mock Intake, a mintable IMD and a test signing key.
abstract contract RegistryBase is Test {
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    uint256 internal constant BOND = 5e18;
    uint64 internal constant COOLDOWN = 1 hours;
    uint256 internal constant QUESTION_CHAIN = 1;
    uint256 internal constant MAINNET_CALLBACK_GAS = 200_000;
    address internal constant STACKER = address(0x57AC);

    MockIntake internal intake;
    MintableIMD internal imd;
    ProjectRegistry internal reg;
    address internal project;
    address internal beneficiary = makeAddr("beneficiary");
    address internal applicant = makeAddr("applicant");
    address internal challenger = makeAddr("challenger");
    uint256 internal uuid;

    function setUp() public virtual {
        vm.roll(1_000);
        vm.warp(1_700_000_000);
        intake = new MockIntake();
        imd = new MintableIMD();
        reg = new ProjectRegistry(
            address(intake),
            address(imd),
            STACKER,
            vm.addr(SIGNER_KEY),
            QUESTION_CHAIN,
            BOND,
            COOLDOWN
        );
        project = address(new MockProject());
        _fund(applicant);
        _fund(challenger);
    }

    function _fund(address who) internal {
        imd.mint(who, 1_000e18);
        vm.prank(who);
        imd.approve(address(reg), type(uint256).max);
    }

    function _apply() internal returns (bytes32 id) {
        vm.prank(applicant);
        id = reg.applyListing(project, "PLEA", "https://github.com/khaed1/plea", 50, beneficiary);
    }

    function _attestation(bool yes) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = bytes32(++uuid << 128);
        a.chainId = QUESTION_CHAIN;
        a.questionHash = keccak256("q");
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(yes);
        a.fromBlock = uint64(block.number - 10);
        a.toBlock = uint64(block.number - 5);
        a.blockHash = keccak256("block");
        a.panelJobId = bytes32(uuid << 128);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 13;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, reg.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Delivers a signed answer through the mock Intake with mainnet's callback gas.
    function _answer(bytes32 id, bool yes) internal returns (bool delivered) {
        OracleAttestation.Attestation memory a = _attestation(yes);
        delivered = intake.deliver(id, a, _sign(a, SIGNER_KEY), MAINNET_CALLBACK_GAS);
    }

    function _listed() internal returns (bytes32 id) {
        id = _apply();
        assertTrue(_answer(id, true), "listing delivered");
        assertTrue(reg.isListed(project));
    }

    function _challenge() internal returns (bytes32 id) {
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(challenger);
        id = reg.challenge(project, "It credits the owner's wallet outside trades.");
    }
}

contract ProjectRegistryTest is RegistryBase {
    // ───────────────────────── constructor and wiring ─────────────────────────

    function test_constructor_wiring() public view {
        assertEq(address(reg.intake()), address(intake));
        assertEq(address(reg.oracleAsset()), address(imd));
        assertEq(reg.stacker(), STACKER);
        assertEq(reg.oracleSigner(), vm.addr(SIGNER_KEY));
        assertEq(reg.questionChainId(), QUESTION_CHAIN);
        assertEq(reg.challengeBond(), BOND);
        assertEq(reg.challengeCooldown(), COOLDOWN);
        assertEq(reg.ACTION(), bytes32("oracle.request@oracle-1"));
        assertEq(reg.onOracleResult.selector, bytes4(0x510379c7), "callback selector");
        assertEq(reg.onOracleFailure.selector, bytes4(0xa7980e31), "failure selector");
    }

    function test_constructor_rejectsZeroAddresses() public {
        address s = vm.addr(SIGNER_KEY);
        vm.expectRevert(ProjectRegistry.ZeroAddress.selector);
        new ProjectRegistry(address(0), address(imd), STACKER, s, 1, BOND, COOLDOWN);
        vm.expectRevert(ProjectRegistry.ZeroAddress.selector);
        new ProjectRegistry(address(intake), address(0), STACKER, s, 1, BOND, COOLDOWN);
        vm.expectRevert(ProjectRegistry.ZeroAddress.selector);
        new ProjectRegistry(address(intake), address(imd), address(0), s, 1, BOND, COOLDOWN);
        vm.expectRevert(OracleAttestationConsumer.ZeroSigner.selector);
        new ProjectRegistry(address(intake), address(imd), STACKER, address(0), 1, BOND, COOLDOWN);
    }

    // ───────────────────────── applying ─────────────────────────

    function test_apply_paysExactlyTheFeeAndAsks() public {
        uint256 before = imd.balanceOf(applicant);
        vm.expectEmit(true, true, false, false, address(reg));
        emit ProjectRegistry.Applied(project, applicant, bytes32(0), 0, address(0), "", "");
        bytes32 id = _apply();

        assertEq(before - imd.balanceOf(applicant), 0.5e18, "fee pulled from the applicant");
        assertEq(imd.balanceOf(intake.TREASURY()), 0.5e18, "fee reached the Intake's treasury");
        assertEq(imd.balanceOf(address(reg)), 0, "registry keeps nothing");
        assertEq(imd.allowance(address(reg), address(intake)), 0, "approval used up exactly");
        assertEq(reg.projectOfIntake(id), project);
        (address payer, address target, bytes4 sel,) = intake.requests(id);
        assertEq(payer, address(reg));
        assertEq(target, address(reg));
        assertEq(sel, reg.onOracleResult.selector);

        ProjectRegistry.Project memory p = reg.projectOf(project);
        assertEq(uint8(p.ask), uint8(ProjectRegistry.Ask.Apply));
        assertEq(p.asker, applicant);
        assertEq(p.intakeId, id);
        assertEq(p.rateBps, 50);
        assertEq(p.beneficiary, beneficiary);
        assertFalse(p.listed);
    }

    function test_apply_bodyIsTheOracleBody() public {
        bytes32 id = _apply();
        string memory body = string(intake.bodyOf(id));
        assertEq(vm.parseJsonUint(body, ".v"), 1);
        assertEq(vm.parseJsonString(body, ".answerType"), "bool");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertEq(
            vm.parseJsonUint(body, ".chainId"), QUESTION_CHAIN, "filed under the oracle's chain"
        );
        assertEq(vm.parseJsonUint(body, ".panelSize"), 15);
        assertEq(vm.parseJsonUint(body, ".quorum"), 11);
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 86400);
        assertEq(vm.parseJsonUint(body, ".window.hours"), 1);
        assertTrue(vm.parseJsonBool(body, ".allowAmbiguous"));
        assertEq(
            vm.parseJsonUint(body, ".consumer.chainId"), block.chainid, "signed for this chain"
        );
        assertEq(
            vm.parseJsonAddress(body, ".consumer.verifyingContract"), address(reg), "signed for us"
        );

        string memory q = vm.parseJsonString(body, ".question");
        assertLe(bytes(q).length, 2000, "question within the oracle's limit");
        assertTrue(vm.contains(q, vm.toLowercase(vm.toString(project))), "names the project");
        assertTrue(vm.contains(q, "[NAME]PLEA[/NAME]"));
        assertTrue(vm.contains(q, "[URL]https://github.com/khaed1/plea[/URL]"));
        assertTrue(vm.contains(q, "50 basis points"));
        string[8] memory keys = [
            "trading",
            "trader",
            "otherPayouts",
            "rate",
            "feeGuard",
            "lockedValue",
            "beneficiary",
            "evidence"
        ];
        for (uint256 i; i < keys.length; ++i) {
            string memory d = vm.parseJsonString(body, string.concat(".definitions.", keys[i]));
            assertGt(bytes(d).length, 0);
            assertLe(bytes(d).length, 512, "definition within the oracle's limit");
        }
        assertTrue(
            vm.contains(
                vm.parseJsonString(body, ".definitions.beneficiary"),
                vm.toLowercase(vm.toString(beneficiary))
            )
        );
    }

    function test_apply_validation() public {
        vm.startPrank(applicant);
        vm.expectRevert(ProjectRegistry.ZeroAddress.selector);
        reg.applyListing(address(0), "X", "https://x.example", 50, beneficiary);
        vm.expectRevert(ProjectRegistry.ZeroAddress.selector);
        reg.applyListing(project, "X", "https://x.example", 50, address(0));
        vm.expectRevert(ProjectRegistry.NotAContract.selector);
        reg.applyListing(makeAddr("wallet"), "X", "https://x.example", 50, beneficiary);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.RateOutOfRange.selector, uint16(24)));
        reg.applyListing(project, "X", "https://x.example", 24, beneficiary);
        vm.expectRevert(
            abi.encodeWithSelector(ProjectRegistry.RateOutOfRange.selector, uint16(101))
        );
        reg.applyListing(project, "X", "https://x.example", 101, beneficiary);
        string[8] memory badNames = [
            "",
            "a\"b",
            "a\\b",
            "a[b",
            "a]b",
            "tab\there",
            unicode"café",
            "0123456789012345678901234567890123456789012345678"
        ];
        for (uint256 i; i < badNames.length; ++i) {
            vm.expectRevert(ProjectRegistry.BadText.selector);
            reg.applyListing(project, badNames[i], "https://x.example", 50, beneficiary);
        }
        vm.expectRevert(ProjectRegistry.BadText.selector);
        reg.applyListing(project, "X", "http://x.example", 50, beneficiary);
        vm.expectRevert(ProjectRegistry.BadText.selector);
        reg.applyListing(project, "X", "https://x.", 50, beneficiary); // 10 bytes, under the minimum
        vm.stopPrank();
    }

    function test_apply_oneOpenQuestionAtATime_andNotWhenListed() public {
        _apply();
        vm.prank(applicant);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.applyListing(project, "Other", "https://x.example", 25, applicant);

        _answer(intake.lastId(), true);
        vm.prank(applicant);
        vm.expectRevert(ProjectRegistry.AlreadyListed.selector);
        reg.applyListing(project, "Again", "https://x.example", 50, beneficiary);
    }

    // ───────────────────────── answers ─────────────────────────

    function test_yes_listsFromThisBlock() public {
        bytes32 id = _apply();
        vm.roll(block.number + 7);
        vm.expectEmit(true, false, false, false, address(reg));
        emit ProjectRegistry.Listed(project, 0, address(0), 0, bytes32(0));
        assertTrue(_answer(id, true), "delivered within mainnet callback gas");

        ProjectRegistry.Project memory p = reg.projectOf(project);
        assertTrue(p.listed);
        assertEq(p.fromBlock, block.number);
        assertEq(p.toBlock, 0);
        assertEq(p.rateBps, 50);
        assertEq(p.beneficiary, beneficiary);
        assertEq(p.challengeOpenAt, block.timestamp + COOLDOWN);
        assertEq(uint8(p.ask), uint8(ProjectRegistry.Ask.None));
        assertEq(p.intakeId, bytes32(0));
        assertEq(reg.projectOfIntake(id), address(0));
    }

    function test_no_rejects_andTheProjectCanApplyAgain() public {
        bytes32 id = _apply();
        vm.expectEmit(true, false, false, false, address(reg));
        emit ProjectRegistry.Rejected(project, bytes32(0));
        assertTrue(_answer(id, false));
        assertFalse(reg.isListed(project));
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));

        bytes32 id2 = _apply();
        assertTrue(id2 != id);
        assertTrue(_answer(id2, true));
        assertTrue(reg.isListed(project));
    }

    function test_answer_onlyFromTheIntake_onlyForOurOpenRequest() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, SIGNER_KEY);

        vm.expectRevert(ProjectRegistry.NotIntake.selector);
        reg.onOracleResult(id, a, sig);

        vm.prank(address(intake));
        vm.expectRevert(
            abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, bytes32(uint256(1)))
        );
        reg.onOracleResult(bytes32(uint256(1)), a, sig);

        assertTrue(intake.deliver(id, a, sig, MAINNET_CALLBACK_GAS));
        // The same answer again: the request is settled, so it is unknown now.
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, id));
        reg.onOracleResult(id, a, sig);
    }

    function test_answer_mustBeSignedByTheOracleForThisContract() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory wrongKey = _sign(a, 0xB0B);
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        reg.onOracleResult(id, a, wrongKey);

        // Signed for another registry: a different EIP-712 domain.
        ProjectRegistry other = new ProjectRegistry(
            address(intake),
            address(imd),
            STACKER,
            vm.addr(SIGNER_KEY),
            QUESTION_CHAIN,
            BOND,
            COOLDOWN
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        reg.onOracleResult(id, a, abi.encodePacked(r, s, v));

        // A tampered answer no longer matches the signature.
        bytes memory sig = _sign(a, SIGNER_KEY);
        a.answer = abi.encode(false);
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        reg.onOracleResult(id, a, sig);
    }

    function test_answer_freshnessAndPanelChecks() public {
        bytes32 id = _apply();

        OracleAttestation.Attestation memory a = _attestation(true);
        a.issuedAt = uint64(block.timestamp - 1 hours); // signed before the question was asked
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.prank(address(intake));
        vm.expectRevert(
            abi.encodeWithSelector(ProjectRegistry.AnswerFromBeforeAsk.selector, a.issuedAt)
        );
        reg.onOracleResult(id, a, sig);

        a = _attestation(true);
        a.expiresAt = uint64(block.timestamp - 1);
        sig = _sign(a, SIGNER_KEY);
        vm.prank(address(intake));
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt
            )
        );
        reg.onOracleResult(id, a, sig);

        uint256[4] memory variant = [uint256(0), 1, 2, 3];
        for (uint256 i; i < variant.length; ++i) {
            a = _attestation(true);
            if (variant[i] == 0) a.chainId = 11155111;
            if (variant[i] == 1) a.panelSize = 14;
            if (variant[i] == 2) a.quorum = 10;
            if (variant[i] == 3) a.agreed = 10;
            sig = _sign(a, SIGNER_KEY);
            vm.prank(address(intake));
            vm.expectRevert(ProjectRegistry.WrongPanel.selector);
            reg.onOracleResult(id, a, sig);
        }

        a = _attestation(true);
        a.answerType = OracleAttestation.ANSWER_UINT256;
        sig = _sign(a, SIGNER_KEY);
        vm.prank(address(intake));
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAttestationConsumer.WrongAnswerType.selector,
                OracleAttestation.ANSWER_BOOL,
                OracleAttestation.ANSWER_UINT256
            )
        );
        reg.onOracleResult(id, a, sig);

        // After a day the question is stale; an answer can't settle it any more.
        vm.warp(block.timestamp + 1 days + 1);
        a = _attestation(true);
        sig = _sign(a, SIGNER_KEY);
        vm.prank(address(intake));
        vm.expectRevert(ProjectRegistry.TooLate.selector);
        reg.onOracleResult(id, a, sig);
    }

    // ───────────────────────── failures and expiry ─────────────────────────

    function test_failure_clearsTheApplication_andNeverLists() public {
        bytes32 id = _apply();
        vm.expectEmit(true, true, false, true, address(reg));
        emit ProjectRegistry.AskCleared(
            project, id, ProjectRegistry.Ask.Apply, 2, bytes32("disagreed")
        );
        assertTrue(intake.fail(id, 2, "disagreed", MAINNET_CALLBACK_GAS));
        assertFalse(reg.isListed(project));
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
        assertEq(reg.projectOfIntake(id), address(0));
        _apply(); // can apply again at once
    }

    function test_failure_onlyFromTheIntake_onlyForOurOpenRequest() public {
        bytes32 id = _apply();
        vm.expectRevert(ProjectRegistry.NotIntake.selector);
        reg.onOracleFailure(id, 2, "disagreed", 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(
            abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, bytes32(uint256(7)))
        );
        reg.onOracleFailure(bytes32(uint256(7)), 1, "refused", 0, 0, "");
    }

    function test_expire_afterADay_orWhenTheIntakeCompletedWithoutAnAnswer() public {
        vm.expectRevert(ProjectRegistry.NothingToExpire.selector);
        reg.expire(project);

        bytes32 id = _apply();
        vm.expectRevert(ProjectRegistry.NotStale.selector);
        reg.expire(project);

        intake.completeSilently(id); // completed, but no callback reached us
        reg.expire(project);
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));

        _apply();
        vm.warp(block.timestamp + 1 days + 1);
        reg.expire(project);
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
    }

    function test_callbackOutOfGas_isRecoverableThroughExpire() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        assertFalse(intake.deliver(id, a, _sign(a, SIGNER_KEY), 30_000), "starved callback fails");
        assertFalse(reg.isListed(project));
        reg.expire(project); // the Intake completed it, so it clears at once
        _apply();
    }

    // ───────────────────────── challenges ─────────────────────────

    function test_challenge_onlyListed_afterCooldown_oneAtATime() public {
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.NotListed.selector);
        reg.challenge(project, "why");

        _listed();
        uint64 openAt = reg.projectOf(project).challengeOpenAt;
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.ChallengeTooSoon.selector, openAt));
        reg.challenge(project, "why");

        _challenge();
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.challenge(project, "again");

        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.BadText.selector);
        reg.challenge(project, "");
    }

    function test_challenge_paysFeeAndBond_bodyNamesTheReason() public {
        _listed();
        uint256 before = imd.balanceOf(challenger);
        bytes32 id = _challenge();
        assertEq(before - imd.balanceOf(challenger), 0.5e18 + BOND);
        assertEq(imd.balanceOf(address(reg)), BOND, "only the bond stays");
        assertEq(imd.allowance(address(reg), address(intake)), 0);
        string memory q = vm.parseJsonString(string(intake.bodyOf(id)), ".question");
        assertTrue(vm.contains(q, "listing challenge"));
        assertTrue(vm.contains(q, "[REASON]It credits the owner's wallet outside trades.[/REASON]"));
    }

    function test_challenge_defended_bondToBeneficiary_noNewCooldown() public {
        _listed();
        uint64 fromBlock = reg.projectOf(project).fromBlock;
        uint64 openAt = reg.projectOf(project).challengeOpenAt;
        bytes32 id = _challenge();
        vm.expectEmit(true, false, false, false, address(reg));
        emit ProjectRegistry.Defended(project, 0, bytes32(0));
        assertTrue(_answer(id, true), "delivered within mainnet callback gas");
        assertEq(imd.balanceOf(beneficiary), BOND);
        assertEq(imd.balanceOf(address(reg)), 0);
        ProjectRegistry.Project memory p = reg.projectOf(project);
        assertTrue(p.listed);
        assertEq(p.fromBlock, fromBlock, "listing unchanged");
        assertEq(p.challengeOpenAt, openAt, "a defended challenge grants no new immunity");
    }

    function test_challenge_lost_delistsFromThisBlock_bondBack() public {
        _listed();
        bytes32 id = _challenge();
        uint256 before = imd.balanceOf(challenger);
        vm.roll(block.number + 3);
        vm.expectEmit(true, false, false, false, address(reg));
        emit ProjectRegistry.Delisted(project, 0, bytes32(0));
        assertTrue(_answer(id, false), "delivered within mainnet callback gas");
        assertEq(imd.balanceOf(challenger) - before, BOND);
        ProjectRegistry.Project memory p = reg.projectOf(project);
        assertFalse(p.listed);
        assertEq(p.toBlock, block.number);
        assertGt(p.fromBlock, 0, "the earlier listing period stays on record");

        // It can apply again; a new listing starts a new period.
        vm.roll(block.number + 10);
        bytes32 id2 = _apply();
        assertTrue(_answer(id2, true));
        p = reg.projectOf(project);
        assertEq(p.fromBlock, block.number);
        assertEq(p.toBlock, 0);
    }

    function test_challenge_failureOrExpiry_returnsTheBond_projectStaysListed() public {
        _listed();
        bytes32 id = _challenge();
        uint256 before = imd.balanceOf(challenger);
        assertTrue(intake.fail(id, 2, "disagreed", MAINNET_CALLBACK_GAS));
        assertEq(imd.balanceOf(challenger) - before, BOND);
        assertTrue(reg.isListed(project));

        _challenge();
        before = imd.balanceOf(challenger);
        vm.warp(block.timestamp + 1 days + 1);
        reg.expire(project);
        assertEq(imd.balanceOf(challenger) - before, BOND);
        assertTrue(reg.isListed(project));
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    // ───────────────────────── beneficiary ─────────────────────────

    function test_setBeneficiary_onlyTheBeneficiaryOfAListedProject() public {
        address next = makeAddr("next");
        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.NotListed.selector);
        reg.setBeneficiary(project, next);

        _listed();
        vm.prank(applicant);
        vm.expectRevert(ProjectRegistry.NotBeneficiary.selector);
        reg.setBeneficiary(project, next);
        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.ZeroAddress.selector);
        reg.setBeneficiary(project, address(0));
        vm.prank(beneficiary);
        reg.setBeneficiary(project, next);
        assertEq(reg.projectOf(project).beneficiary, next);
    }

    // ───────────────────────── fuzz ─────────────────────────

    /// @dev Any name is either refused or made only of the allowed bytes, so the body never needs
    /// escaping and always parses.
    function testFuzz_apply_nameIsSafeOrRefused(bytes memory raw) public {
        vm.assume(raw.length <= 64);
        bool ok = raw.length >= 1 && raw.length <= 48;
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            if (c < 0x20 || c > 0x7e || c == '"' || c == "\\" || c == "[" || c == "]") ok = false;
        }
        vm.prank(applicant);
        if (!ok) {
            vm.expectRevert(ProjectRegistry.BadText.selector);
            reg.applyListing(project, string(raw), "https://x.example", 50, beneficiary);
            return;
        }
        bytes32 id = reg.applyListing(project, string(raw), "https://x.example", 50, beneficiary);
        string memory q = vm.parseJsonString(string(intake.bodyOf(id)), ".question");
        assertTrue(vm.contains(q, string.concat("[NAME]", string(raw), "[/NAME]")));
    }

    function testFuzz_apply_rate(uint16 rate) public {
        vm.prank(applicant);
        if (rate < 25 || rate > 100) {
            vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.RateOutOfRange.selector, rate));
            reg.applyListing(project, "X", "https://x.example", rate, beneficiary);
        } else {
            reg.applyListing(project, "X", "https://x.example", rate, beneficiary);
            assertEq(reg.projectOf(project).rateBps, rate);
        }
    }
}
