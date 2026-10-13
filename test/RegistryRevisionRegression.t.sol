// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryBase} from "./ProjectRegistry.t.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/oracle/OracleAttestation.sol";
import {MockProject} from "./mocks/MockIntake.sol";

contract RateChangingProject {
    uint16 public rateBps = 50;

    function setRate(uint16 rate) external {
        require(rate >= 25 && rate <= 100);
        rateBps = rate;
    }
}

contract RegistryRevisionRegressionTest is RegistryBase {
    function test_openChallengeLocksBeneficiaryAndDefendedBondDestination() public {
        _listed();
        bytes32 id = _challenge();
        address next = makeAddr("next beneficiary");
        string memory rule =
            vm.parseJsonString(string(intake.bodyOf(id)), ".definitions.beneficiary");
        assertTrue(vm.contains(rule, vm.toLowercase(vm.toString(beneficiary))));

        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.setBeneficiary(project, next);
        assertEq(reg.projectOf(project).beneficiary, beneficiary);
        assertTrue(_answer(id, true));
        assertEq(imd.balanceOf(beneficiary), BOND);
        assertEq(imd.balanceOf(next), 0);
        vm.prank(beneficiary);
        reg.setBeneficiary(project, next);
        assertEq(reg.projectOf(project).beneficiary, next);
        assertTrue(reg.beneficiaryPinRequired(project));
    }

    function testFuzz_beneficiaryUnlocksAfterFailureOrExpiry(bool failure) public {
        _listed();
        bytes32 id = _challenge();
        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.setBeneficiary(project, applicant);
        if (failure) {
            assertTrue(intake.fail(id, 2, "disagreed", 200_000));
        } else {
            vm.warp(block.timestamp + 1 days + 1);
            reg.expire(project);
        }
        vm.prank(beneficiary);
        reg.setBeneficiary(project, applicant);
        assertEq(reg.projectOf(project).beneficiary, applicant);
        assertEq(imd.balanceOf(challenger), 1_000e18 - 0.5e18);
    }

    function test_beneficiaryCannotTransferAfterChallengeDelists() public {
        _listed();
        bytes32 id = _challenge();
        assertTrue(_answer(id, false));
        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.NotListed.selector);
        reg.setBeneficiary(project, applicant);
        assertEq(imd.balanceOf(challenger), 1_000e18 - 0.5e18);
    }

    function test_pinnedChallengeRefusesFrontrunBeforeAnyPayment() public {
        _listed();
        vm.warp(block.timestamp + COOLDOWN);
        address team = makeAddr("team");
        vm.prank(beneficiary);
        reg.setBeneficiary(project, team); // Included ahead of the challenger's transaction.

        uint256 balance = imd.balanceOf(challenger);
        uint256 allowance = imd.allowance(challenger, address(reg));
        uint256 count = intake.count();
        vm.prank(challenger);
        vm.expectRevert(
            abi.encodeWithSelector(ProjectRegistry.BeneficiaryChanged.selector, beneficiary, team)
        );
        reg.challengeForBeneficiary(project, "The beneficiary is an outsider.", beneficiary);
        assertEq(imd.balanceOf(challenger), balance);
        assertEq(imd.allowance(challenger, address(reg)), allowance);
        assertEq(imd.balanceOf(address(reg)), 0);
        assertEq(intake.count(), count);
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));

        // Restoring the old wallet restores the terms the challenger actually wanted judged
        // (after the handoff interval: one handoff per day, so a front-run cannot be undone).
        vm.warp(block.timestamp + reg.HANDOFF_INTERVAL());
        vm.prank(team);
        reg.setBeneficiary(project, beneficiary);
        vm.prank(challenger);
        bytes32 id =
            reg.challengeForBeneficiary(project, "The beneficiary is an outsider.", beneficiary);
        string memory rule =
            vm.parseJsonString(string(intake.bodyOf(id)), ".definitions.beneficiary");
        assertTrue(vm.contains(rule, vm.toLowercase(vm.toString(beneficiary))));
        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.setBeneficiary(project, team);
        assertTrue(_answer(id, false));
        assertFalse(reg.isListed(project));
        assertEq(balance - imd.balanceOf(challenger), 0.5e18);
    }

    function test_legacyChallengeCannotChargeAfterAnyBeneficiaryHandoff() public {
        _listed();
        vm.warp(block.timestamp + COOLDOWN);
        address team = makeAddr("team");
        uint256 balance = imd.balanceOf(challenger);
        uint256 count = intake.count();
        // The attacker cannot replace the terms of a pending legacy challenge and take its bond.
        vm.prank(beneficiary);
        reg.setBeneficiary(project, team);
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.BeneficiaryPinRequired.selector);
        reg.challenge(project, "The beneficiary is an outsider.");
        assertEq(imd.balanceOf(challenger), balance);
        assertEq(intake.count(), count);
        vm.warp(block.timestamp + reg.HANDOFF_INTERVAL());
        vm.prank(team);
        reg.setBeneficiary(project, beneficiary);
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.BeneficiaryPinRequired.selector);
        reg.challenge(project, "The beneficiary is an outsider.");
        assertEq(imd.balanceOf(challenger), balance);
        // A pinned challenge still works; delisting/relisting cannot re-enable the unsafe API.
        vm.prank(challenger);
        bytes32 id =
            reg.challengeForBeneficiary(project, "The beneficiary is an outsider.", beneficiary);
        assertTrue(_answer(id, false));
        _listed();
        vm.warp(block.timestamp + COOLDOWN);
        assertTrue(reg.beneficiaryPinRequired(project));
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.BeneficiaryPinRequired.selector);
        reg.challenge(project, "Review again.");
        vm.prank(challenger);
        id = reg.challengeForBeneficiary(project, "Review again.", beneficiary);
        assertTrue(_answer(id, true));
    }

    function test_settingSameBeneficiaryDoesNotDisableLegacyChallenge() public {
        _listed();
        vm.prank(beneficiary);
        reg.setBeneficiary(project, beneficiary);
        assertFalse(reg.beneficiaryPinRequired(project));
        assertEq(reg.handoffOpenAt(project), 0, "a no-op is not a handoff");
        assertTrue(_answer(_challenge(), true));
    }

    /// @dev Reviewer finding 047a2339: a beneficiary watching the mempool could refuse every
    /// `challengeForBeneficiary` for free by moving the wallet ahead of each attempt and back
    /// before the next. One handoff per `HANDOFF_INTERVAL` ends that: the retry against the
    /// wallet now in force lands, with the fee and bond paid once and a question filed.
    function test_beneficiaryCannotBlockEveryChallengeByTogglingWallets() public {
        _listed();
        vm.warp(block.timestamp + COOLDOWN);
        address other = makeAddr("beneficiary's other wallet");
        uint256 balance = imd.balanceOf(challenger);
        uint256 count = intake.count();

        // Round 1: the challenger saw `beneficiary`; the handoff is included first.
        vm.prank(beneficiary);
        reg.setBeneficiary(project, other);
        vm.prank(challenger);
        vm.expectRevert(
            abi.encodeWithSelector(ProjectRegistry.BeneficiaryChanged.selector, beneficiary, other)
        );
        reg.challengeForBeneficiary(project, "rate guard removed in v2", beneficiary);
        assertEq(imd.balanceOf(challenger), balance, "front-run costs the challenger nothing");

        // Round 2: the challenger names `other`; moving back is refused for a day.
        uint64 openAt = reg.handoffOpenAt(project);
        assertEq(openAt, uint64(block.timestamp) + reg.HANDOFF_INTERVAL());
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.HandoffTooSoon.selector, openAt));
        reg.setBeneficiary(project, beneficiary);
        vm.prank(challenger);
        bytes32 id = reg.challengeForBeneficiary(project, "rate guard removed in v2", other);
        assertEq(intake.count(), count + 1, "the challenge is filed");
        assertEq(balance - imd.balanceOf(challenger), 0.5e18 + BOND);
        string memory rule =
            vm.parseJsonString(string(intake.bodyOf(id)), ".definitions.beneficiary");
        assertTrue(vm.contains(rule, vm.toLowercase(vm.toString(other))));
        assertTrue(_answer(id, false));
        assertFalse(reg.isListed(project));
        assertEq(balance - imd.balanceOf(challenger), 0.5e18, "bond back on a delisting");
    }

    function test_handoffIntervalBoundaryAndRelisting() public {
        _listed();
        address team = makeAddr("team");
        vm.prank(beneficiary);
        reg.setBeneficiary(project, team);
        uint64 openAt = reg.handoffOpenAt(project);
        assertEq(openAt, uint64(block.timestamp) + 1 days);

        // The same wallet can be set again at any time; a different one must wait.
        vm.prank(team);
        reg.setBeneficiary(project, team);
        assertEq(reg.handoffOpenAt(project), openAt, "a no-op does not restart the interval");
        vm.warp(openAt - 1);
        vm.prank(team);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.HandoffTooSoon.selector, openAt));
        reg.setBeneficiary(project, beneficiary);
        // A defended challenge in between changes nothing about the interval.
        vm.prank(challenger);
        bytes32 id = reg.challengeForBeneficiary(project, "Review the team wallet.", team);
        assertTrue(_answer(id, true));
        assertEq(imd.balanceOf(team), BOND);
        assertEq(reg.handoffOpenAt(project), openAt);
        vm.warp(openAt);
        vm.prank(team);
        reg.setBeneficiary(project, beneficiary);
        assertEq(reg.projectOf(project).beneficiary, beneficiary);
        assertEq(reg.handoffOpenAt(project), openAt + 1 days);

        // Delisting and relisting (an application names any beneficiary) keep the interval.
        vm.prank(challenger);
        id = reg.challengeForBeneficiary(project, "Review again.", beneficiary);
        assertTrue(_answer(id, false));
        _listed();
        assertEq(reg.handoffOpenAt(project), openAt + 1 days);
        vm.prank(beneficiary);
        vm.expectRevert(
            abi.encodeWithSelector(ProjectRegistry.HandoffTooSoon.selector, openAt + 1 days)
        );
        reg.setBeneficiary(project, team);
    }

    function test_pinnedChallengePreservesCooldownAndSlotRules() public {
        vm.expectRevert(ProjectRegistry.NotListed.selector);
        reg.challengeForBeneficiary(project, "Review this project.", beneficiary);
        _listed();
        uint64 openAt = reg.projectOf(project).challengeOpenAt;
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.ChallengeTooSoon.selector, openAt));
        reg.challengeForBeneficiary(project, "Review this project.", beneficiary);
        vm.warp(openAt);
        vm.prank(challenger);
        bytes32 id = reg.challengeForBeneficiary(project, "Review this project.", beneficiary);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.challengeForBeneficiary(project, "Another review.", beneficiary);
        assertTrue(_answer(id, true));
        assertEq(imd.balanceOf(beneficiary), BOND);
        assertEq(reg.projectOf(project).challengeOpenAt, openAt);
    }

    function testFuzz_answerIsConsumedAcrossApplications(bool yes) public {
        bytes32 first = _apply();
        address secondProject = address(new MockProject());
        vm.prank(applicant);
        bytes32 second =
            reg.applyListing(secondProject, "Two", "https://example.org/two", 50, beneficiary);
        OracleAttestation.Attestation memory a = _attestation(yes);
        bytes memory sig = _sign(a, SIGNER_KEY);
        assertTrue(intake.deliver(first, a, sig, 200_000));
        assertTrue(reg.consumed(a.requestId));
        vm.prank(address(intake));
        vm.expectRevert(
            abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId)
        );
        reg.onOracleResult(second, a, sig);
        assertFalse(intake.deliver(second, a, sig, 200_000));
        assertFalse(reg.isListed(secondProject));
        assertEq(reg.projectOfIntake(second), secondProject);
        // The real Intake does not retry a failed callback. Expiry/reapplication remains available.
        reg.expire(secondProject);
        vm.prank(applicant);
        bytes32 retry =
            reg.applyListing(secondProject, "Two", "https://example.org/two", 50, beneficiary);
        assertTrue(_answer(retry, true));
        assertTrue(reg.isListed(secondProject));
    }

    function test_applicationAnswerCannotDefendAChallengeAndSpendItsBond() public {
        bytes32 first = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, SIGNER_KEY);
        assertTrue(intake.deliver(first, a, sig, 200_000));
        vm.warp(block.timestamp + COOLDOWN);
        // Refreshing the signed window with the same UUID must not bypass consumption.
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        sig = _sign(a, SIGNER_KEY);
        vm.prank(challenger);
        bytes32 id = reg.challengeForBeneficiary(project, "Review this project.", beneficiary);
        assertFalse(intake.deliver(id, a, sig, 200_000));
        assertEq(imd.balanceOf(beneficiary), 0);
        assertEq(imd.balanceOf(address(reg)), BOND);
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.Challenge));
        reg.expire(project); // Intake completed the failed callback; refund remains available.
        assertEq(imd.balanceOf(challenger), 1_000e18 - 0.5e18);
    }

    function test_invalidAnswerDoesNotConsumeUUID() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        a.agreed = 10;
        assertFalse(intake.deliver(id, a, _sign(a, SIGNER_KEY), 200_000));
        assertFalse(reg.consumed(a.requestId));
        a.agreed = 13;
        assertFalse(intake.deliver(id, a, _sign(a, SIGNER_KEY + 1), 200_000));
        assertFalse(reg.consumed(a.requestId));
        assertTrue(intake.deliver(id, a, _sign(a, SIGNER_KEY), 200_000));
        assertTrue(reg.consumed(a.requestId));
    }

    function test_constructorRefusesOverflowingAndExcessiveCooldowns() public {
        address signer = vm.addr(SIGNER_KEY);
        uint64 limit = reg.MAX_CHALLENGE_COOLDOWN();
        vm.expectRevert(ProjectRegistry.CooldownOutOfRange.selector);
        new ProjectRegistry(
            address(intake), address(imd), STACKER, signer, 1, BOND, type(uint64).max
        );
        vm.expectRevert(ProjectRegistry.CooldownOutOfRange.selector);
        new ProjectRegistry(address(intake), address(imd), STACKER, signer, 1, BOND, limit + 1);
    }

    function testFuzz_validCooldownCanList(uint64 cooldown) public {
        cooldown = uint64(bound(cooldown, 0, reg.MAX_CHALLENGE_COOLDOWN()));
        _assertCooldownLists(cooldown);
    }

    function test_zeroAndMaximumCooldownCanList() public {
        uint64 limit = reg.MAX_CHALLENGE_COOLDOWN();
        _assertCooldownLists(0);
        _assertCooldownLists(limit);
    }

    function _assertCooldownLists(uint64 cooldown) internal {
        reg = new ProjectRegistry(
            address(intake), address(imd), STACKER, vm.addr(SIGNER_KEY), 1, BOND, cooldown
        );
        _fund(applicant);
        assertTrue(_answer(_apply(), true), "valid cooldown must settle within 200k");
        assertEq(reg.projectOf(project).challengeOpenAt, block.timestamp + cooldown);
    }

    function testFuzz_challengeAllowsRateChangesWithinTheRules(uint16 rate) public {
        rate = uint16(bound(rate, 25, 100));
        RateChangingProject venue = new RateChangingProject();
        project = address(venue);
        bytes32 application = _listed();
        string memory applyRule =
            vm.parseJsonString(string(intake.bodyOf(application)), ".definitions.rate");
        assertTrue(vm.contains(applyRule, "50 must be the rate in force now"));
        venue.setRate(rate);
        assertEq(venue.rateBps(), rate);
        bytes32 id = _challenge();
        string memory body = string(intake.bodyOf(id));
        string memory rule = vm.parseJsonString(body, ".definitions.rate");
        assertTrue(vm.contains(rule, "between 25 and 100"));
        assertTrue(vm.contains(rule, "Judge the rate in force now"));
        assertTrue(vm.contains(rule, "historical and may differ"));
        assertFalse(vm.contains(rule, "50 must be the rate in force now"));
        assertTrue(
            vm.contains(
                vm.parseJsonString(body, ".question"), "historical; the current rate may differ"
            )
        );
        assertEq(
            vm.parseJsonString(body, ".definitions.feeGuard"),
            vm.parseJsonString(string(intake.bodyOf(application)), ".definitions.feeGuard")
        );
        assertTrue(_answer(id, true));
        assertTrue(reg.isListed(project));
        assertEq(reg.projectOf(project).rateBps, 50, "application metadata stays historical");
    }

    function test_challengeBodyLimitsAndConsumerDomain() public {
        _listed();
        vm.warp(block.timestamp + COOLDOWN);
        bytes memory reason = new bytes(280);
        for (uint256 i; i < reason.length; ++i) {
            reason[i] = "x";
        }
        vm.prank(challenger);
        bytes32 id = reg.challengeForBeneficiary(project, string(reason), beneficiary);
        string memory body = string(intake.bodyOf(id));
        assertLe(bytes(body).length, 16_384);
        assertLe(bytes(vm.parseJsonString(body, ".question")).length, 2000);
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
            assertLe(
                bytes(vm.parseJsonString(body, string.concat(".definitions.", keys[i]))).length, 512
            );
        }
        assertEq(vm.parseJsonUint(body, ".consumer.chainId"), block.chainid);
        assertEq(vm.parseJsonAddress(body, ".consumer.verifyingContract"), address(reg));
    }

    // Retained limit: anyone can buy the one slot. A defense no longer renews immunity.
    function test_selfChallengeOccupiesSlotOnlyUntilItSettles() public {
        _listed();
        _fund(beneficiary);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(beneficiary);
        bytes32 id = reg.challengeForBeneficiary(project, "routine check", beneficiary);
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.challengeForBeneficiary(project, "It credits outside trades.", beneficiary);
        assertTrue(_answer(id, true));
        vm.prank(challenger);
        reg.challengeForBeneficiary(project, "It credits outside trades.", beneficiary);
    }
}
