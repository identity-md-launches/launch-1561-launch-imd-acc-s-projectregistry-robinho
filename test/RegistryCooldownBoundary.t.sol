// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {RegistryBase} from "./ProjectRegistry.t.sol";

/// @dev Edges of the Sepolia run's 3600 s challenge cooldown and constructor bound.
contract RegistryCooldownBoundaryTest is RegistryBase {
    function test_challengeOneSecondBeforeCooldown_reverts() public {
        _listed();
        uint64 openAt = reg.projectOf(project).challengeOpenAt;
        vm.warp(openAt - 1);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.ChallengeTooSoon.selector, openAt));
        reg.challenge(project, "too soon");
    }

    function test_challengeExactlyAtCooldown_succeeds() public {
        _listed();
        vm.warp(reg.projectOf(project).challengeOpenAt);
        vm.prank(challenger);
        reg.challenge(project, "on time");
    }

    function test_keptChallenge_doesNotRestartCooldown() public {
        _listed();
        uint64 openAt = reg.projectOf(project).challengeOpenAt;
        bytes32 id = _challenge();
        assertTrue(_answer(id, true));
        assertTrue(reg.isListed(project));
        assertEq(reg.projectOf(project).challengeOpenAt, openAt, "cooldown unchanged");
        // a second challenge is allowed immediately
        vm.prank(challenger);
        reg.challenge(project, "again");
    }

    function test_constructor_rejectsCooldownAboveMax() public {
        uint64 max = reg.MAX_CHALLENGE_COOLDOWN();
        address s = vm.addr(SIGNER_KEY);
        vm.expectRevert(ProjectRegistry.CooldownOutOfRange.selector);
        new ProjectRegistry(address(intake), address(imd), STACKER, s, 1, BOND, max + 1);
        new ProjectRegistry(address(intake), address(imd), STACKER, s, 1, BOND, max);
    }
}
