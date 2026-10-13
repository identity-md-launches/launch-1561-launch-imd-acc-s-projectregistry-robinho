// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {RegistryBase} from "./ProjectRegistry.t.sol";

/// @dev Edges of the one-handoff-per-day rule (`HANDOFF_INTERVAL`) added to `setBeneficiary` for
/// reviewer finding 047a2339: which checks come first inside the interval, the exact boundary at
/// any elapsed time, what an application and an expired question do to the clock, and the
/// property the rule exists for: inside the interval a challenger naming the wallet in force
/// always gets a question filed.
contract RegistryHandoffIntervalTest is RegistryBase {
    address internal team = makeAddr("team");
    address internal third = makeAddr("third wallet");

    function _handedOff() internal returns (uint64 openAt) {
        _listed();
        vm.prank(beneficiary);
        reg.setBeneficiary(project, team);
        openAt = reg.handoffOpenAt(project);
        assertEq(openAt, uint64(block.timestamp) + reg.HANDOFF_INTERVAL());
    }

    function test_handoffEmitsEventAndStartsExactInterval() public {
        _listed();
        assertEq(reg.handoffOpenAt(project), 0, "no clock before the first handoff");
        assertFalse(reg.beneficiaryPinRequired(project));
        vm.expectEmit(true, false, false, true, address(reg));
        emit ProjectRegistry.BeneficiarySet(project, team);
        vm.prank(beneficiary);
        reg.setBeneficiary(project, team);
        assertEq(reg.handoffOpenAt(project), uint64(block.timestamp) + 1 days);
        assertTrue(reg.beneficiaryPinRequired(project));
        assertEq(reg.projectOf(project).beneficiary, team);
    }

    /// @dev The interval refuses every other wallet, not only a move back to the previous one.
    function test_intervalRefusesAThirdWalletToo() public {
        uint64 openAt = _handedOff();
        vm.prank(team);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.HandoffTooSoon.selector, openAt));
        reg.setBeneficiary(project, third);
        // The same wallet is still a no-op at any time, and leaves the clock alone.
        vm.prank(team);
        reg.setBeneficiary(project, team);
        assertEq(reg.handoffOpenAt(project), openAt);
        assertEq(reg.projectOf(project).beneficiary, team);
    }

    /// @dev Inside the interval the earlier checks still win: an outsider or the previous wallet
    /// gets NotBeneficiary, a zero wallet ZeroAddress, an open question AskOpen, a delisted
    /// project NotListed. HandoffTooSoon is only reported to the wallet that could hand off.
    function test_checksBeforeTheIntervalStillComeFirst() public {
        uint64 openAt = _handedOff();
        assertLt(block.timestamp, openAt);

        vm.prank(beneficiary); // the previous wallet, no longer in charge
        vm.expectRevert(ProjectRegistry.NotBeneficiary.selector);
        reg.setBeneficiary(project, beneficiary);
        vm.prank(third);
        vm.expectRevert(ProjectRegistry.NotBeneficiary.selector);
        reg.setBeneficiary(project, third);
        vm.prank(team);
        vm.expectRevert(ProjectRegistry.ZeroAddress.selector);
        reg.setBeneficiary(project, address(0));

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(challenger);
        bytes32 id = reg.challengeForBeneficiary(project, "Review the handoff.", team);
        vm.prank(team);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.setBeneficiary(project, third);
        assertTrue(_answer(id, false));
        assertFalse(reg.isListed(project));
        vm.prank(team);
        vm.expectRevert(ProjectRegistry.NotListed.selector);
        reg.setBeneficiary(project, third);
        assertEq(reg.handoffOpenAt(project), openAt, "a delisting does not touch the clock");
    }

    /// forge-config: default.fuzz.runs = 1000
    /// @dev At any elapsed time short of the interval a second handoff is refused with the exact
    /// opening time; from the opening time on it succeeds and the next interval runs from the
    /// second handoff, not from the first.
    function testFuzz_secondHandoffBoundary(uint64 elapsed) public {
        uint64 interval = reg.HANDOFF_INTERVAL();
        elapsed = uint64(bound(elapsed, 0, 2 * interval));
        uint64 openAt = _handedOff();
        vm.warp(block.timestamp + elapsed);
        vm.prank(team);
        if (elapsed < interval) {
            vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.HandoffTooSoon.selector, openAt));
            reg.setBeneficiary(project, third);
            assertEq(reg.projectOf(project).beneficiary, team, "refused handoff changes nothing");
            assertEq(reg.handoffOpenAt(project), openAt);
        } else {
            reg.setBeneficiary(project, third);
            assertEq(reg.projectOf(project).beneficiary, third);
            assertEq(reg.handoffOpenAt(project), uint64(block.timestamp) + interval);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    /// @dev The property the interval buys: after a handoff, at any time before the next one
    /// opens, the beneficiary cannot move the wallet ahead of a challenge, so a challenge naming
    /// the wallet in force is filed and charged exactly once. The legacy entry point stays closed.
    function testFuzz_challengeNamingTheWalletInForceAlwaysFiles(uint64 elapsed) public {
        uint64 openAt = _handedOff();
        elapsed = uint64(bound(elapsed, COOLDOWN, reg.HANDOFF_INTERVAL() - 1));
        vm.warp(block.timestamp + elapsed);

        // The beneficiary sees the challenge coming and tries to invalidate it: refused.
        vm.prank(team);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.HandoffTooSoon.selector, openAt));
        reg.setBeneficiary(project, third);

        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.BeneficiaryPinRequired.selector);
        reg.challenge(project, "legacy path");

        uint256 balance = imd.balanceOf(challenger);
        uint256 count = intake.count();
        vm.prank(challenger);
        bytes32 id = reg.challengeForBeneficiary(project, "rate guard removed", team);
        assertEq(intake.count(), count + 1, "one question filed");
        assertEq(balance - imd.balanceOf(challenger), 0.5e18 + BOND, "fee and bond paid once");
        ProjectRegistry.Project memory p = reg.projectOf(project);
        assertEq(uint8(p.ask), uint8(ProjectRegistry.Ask.Challenge));
        assertEq(p.asker, challenger);
        assertEq(p.beneficiary, team, "the question is about the wallet in force");
        assertEq(reg.projectOfIntake(id), project);
        // A defended challenge pays the bond to that same wallet and keeps the clock.
        assertTrue(_answer(id, true));
        assertEq(imd.balanceOf(team), BOND);
        assertEq(reg.handoffOpenAt(project), openAt);
    }

    /// @dev An application names its beneficiary outright: that is the panel's call, not a
    /// handoff, so it neither needs the interval nor restarts it, and the pin stays. The new
    /// beneficiary then inherits what is left of the previous wallet's interval.
    function test_relistingByApplicationNamesANewWalletWithoutAHandoff() public {
        uint64 openAt = _handedOff();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(challenger);
        bytes32 id = reg.challengeForBeneficiary(project, "Delist it.", team);
        assertTrue(_answer(id, false));
        assertFalse(reg.isListed(project));

        vm.prank(applicant);
        id = reg.applyListing(project, "PLEA", "https://github.com/khaed1/plea", 75, third);
        assertEq(reg.projectOf(project).beneficiary, third, "stated while the application is open");
        assertEq(reg.handoffOpenAt(project), openAt, "an application is not a handoff");
        assertTrue(reg.beneficiaryPinRequired(project), "the pin survives a relisting");
        assertTrue(_answer(id, true));
        assertTrue(reg.isListed(project));
        assertEq(reg.projectOf(project).beneficiary, third);
        assertEq(reg.projectOf(project).rateBps, 75);

        // Still inside the first wallet's interval: the new beneficiary waits too.
        assertLt(block.timestamp, openAt);
        vm.prank(third);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.HandoffTooSoon.selector, openAt));
        reg.setBeneficiary(project, team);
        // The legacy entry point stays closed for good; the pinned one works at once (new
        // listing, cooldown from the new listing).
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.BeneficiaryPinRequired.selector);
        reg.challenge(project, "legacy");
        vm.prank(challenger);
        reg.challengeForBeneficiary(project, "pinned", third);

        // A rejected application leaves the stated wallet in the record but nothing listed, so
        // it can neither hand off nor be challenged.
        assertTrue(_answer(reg.projectOf(project).intakeId, true));
        vm.warp(openAt);
        vm.prank(third);
        reg.setBeneficiary(project, team);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(challenger);
        id = reg.challengeForBeneficiary(project, "Delist again.", team);
        assertTrue(_answer(id, false));
        vm.prank(applicant);
        id = reg.applyListing(project, "PLEA", "https://github.com/khaed1/plea", 50, beneficiary);
        assertTrue(_answer(id, false));
        assertFalse(reg.isListed(project));
        assertEq(reg.projectOf(project).beneficiary, beneficiary);
        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.NotListed.selector);
        reg.setBeneficiary(project, third);
    }

    /// @dev A challenge that is never answered and is cleared by `expire` (or by the Intake's
    /// failure call) is not a handoff: the clock is untouched, and the next handoff opens when
    /// it would have anyway.
    function test_expiredAndFailedQuestionsLeaveTheClockAlone() public {
        uint64 openAt = _handedOff();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(challenger);
        bytes32 id = reg.challengeForBeneficiary(project, "Stale.", team);
        assertTrue(intake.fail(id, 2, "disagreed", MAINNET_CALLBACK_GAS));
        assertEq(reg.handoffOpenAt(project), openAt);
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));

        vm.prank(challenger);
        reg.challengeForBeneficiary(project, "Stale again.", team);
        vm.prank(team);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.setBeneficiary(project, third);
        vm.warp(block.timestamp + reg.PENDING_EXPIRY() + 1);
        reg.expire(project);
        assertEq(reg.handoffOpenAt(project), openAt);
        assertGe(block.timestamp, openAt);
        vm.prank(team);
        reg.setBeneficiary(project, third);
        assertEq(reg.handoffOpenAt(project), uint64(block.timestamp) + reg.HANDOFF_INTERVAL());
    }

    /// @dev Each project has its own clock: a handoff on one never paces another.
    function test_clockIsPerProject() public {
        uint64 openAt = _handedOff();
        address other = address(new MockProjectTwo());
        vm.prank(applicant);
        bytes32 id = reg.applyListing(other, "Other", "https://example.org/other", 25, beneficiary);
        assertTrue(_answer(id, true));
        assertEq(reg.handoffOpenAt(other), 0);
        vm.prank(beneficiary);
        reg.setBeneficiary(other, third);
        assertEq(reg.handoffOpenAt(other), uint64(block.timestamp) + 1 days);
        assertEq(reg.handoffOpenAt(project), openAt);
        assertEq(reg.projectOf(project).beneficiary, team);
    }
}

contract MockProjectTwo {}
