// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryBase} from "./ProjectRegistry.t.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/oracle/OracleAttestation.sol";
import {TestIMD} from "./mocks/TestIMD.sol";

contract RegistryAuditRegressionTest is RegistryBase {
    function test_defendedSelfChallengeDoesNotRenewImmunity() public {
        _listed();
        _fund(beneficiary);
        uint64 openAt = reg.projectOf(project).challengeOpenAt;
        vm.warp(openAt);
        for (uint256 i; i < 3; ++i) {
            vm.prank(beneficiary);
            bytes32 id = reg.challenge(project, "routine check");
            assertTrue(_answer(id, true));
            assertEq(reg.projectOf(project).challengeOpenAt, openAt);
            // An honest challenger gets an opportunity at once, without an extra cooldown.
            vm.prank(challenger);
            id = reg.challenge(project, "It credits wallets outside trades.");
            assertTrue(_answer(id, true));
        }
    }

    function test_defendedChallengeFromAnotherWalletDoesNotRenewImmunity() public {
        _listed();
        uint64 openAt = reg.projectOf(project).challengeOpenAt;
        vm.prank(beneficiary);
        reg.setBeneficiary(project, challenger);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(challenger);
        bytes32 id =
            reg.challengeForBeneficiary(project, "Review after a beneficiary handoff.", challenger);
        assertTrue(_answer(id, true));
        assertEq(reg.projectOf(project).challengeOpenAt, openAt);
        vm.prank(applicant);
        reg.challengeForBeneficiary(project, "Another reason to review the project.", challenger);
    }

    function testFuzz_applicationPaysCurrentPrice(uint96 rawPrice) public {
        uint256 fee = bound(uint256(rawPrice), 1, 100e18);
        intake.setPrice(fee);
        assertEq(reg.ORACLE_FEE(), fee);
        uint256 before = imd.balanceOf(applicant);
        _apply();
        assertEq(before - imd.balanceOf(applicant), fee);
        assertEq(imd.balanceOf(intake.TREASURY()), fee);
        assertEq(imd.balanceOf(address(reg)), 0);
        assertEq(imd.allowance(address(reg), address(intake)), 0);
    }

    function test_priceRiseAndFall_preserveBondAndExactPayment() public {
        _listed();
        intake.setPrice(0.6e18);
        uint256 before = imd.balanceOf(challenger);
        bytes32 id = _challenge();
        assertEq(before - imd.balanceOf(challenger), BOND + 0.6e18);
        assertEq(imd.balanceOf(address(reg)), BOND);
        assertTrue(_answer(id, true));
        intake.setPrice(0.2e18);
        before = imd.balanceOf(challenger);
        vm.prank(challenger);
        id = reg.challenge(project, "Another review.");
        assertEq(before - imd.balanceOf(challenger), BOND + 0.2e18);
        assertTrue(_answer(id, false));
        assertEq(before - imd.balanceOf(challenger), 0.2e18);
        assertEq(imd.balanceOf(address(reg)), 0);
        assertEq(imd.allowance(address(reg), address(intake)), 0);
    }

    function test_staleExactApprovalCannotSpendAnUnexpectedPriceIncrease() public {
        uint256 quote = reg.ORACLE_FEE();
        vm.prank(applicant);
        imd.approve(address(reg), quote);
        intake.setPrice(0.6e18);
        uint256 before = imd.balanceOf(applicant);
        vm.expectRevert();
        _apply();
        assertEq(imd.balanceOf(applicant), before);
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
        assertEq(intake.count(), 0);
    }

    function test_retiredActionRefusesBeforePaymentAndPreservesListing() public {
        _listed();
        intake.setPrice(0);
        uint256 before = imd.balanceOf(challenger);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.OracleUnavailable.selector);
        reg.challenge(project, "Review this project.");
        assertTrue(
            reg.isListed(project), "retirement needs a replacement registry; no admin is added"
        );
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
        assertEq(imd.balanceOf(challenger), before);
        intake.setPrice(0.8e18);
        vm.prank(challenger);
        reg.challenge(project, "Review once the action is sold again.");
    }

    function test_retiredActionApplicationMovesNothing() public {
        intake.setPrice(0);
        uint256 before = imd.balanceOf(applicant);
        vm.expectRevert(ProjectRegistry.OracleUnavailable.selector);
        _apply();
        assertEq(imd.balanceOf(applicant), before);
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
    }

    function test_signedAnswerMustReachItsOwnQuorum() public {
        bytes32 id = _apply();
        OracleAttestation.Attestation memory a = _attestation(true);
        a.quorum = 14;
        a.agreed = 11;
        bytes memory sig = _sign(a, SIGNER_KEY);
        vm.prank(address(intake));
        vm.expectRevert(ProjectRegistry.WrongPanel.selector);
        reg.onOracleResult(id, a, sig);
        assertFalse(reg.isListed(project));
        assertEq(reg.projectOfIntake(id), project);
        a.agreed = 14;
        assertTrue(intake.deliver(id, a, _sign(a, SIGNER_KEY), MAINNET_CALLBACK_GAS));
        assertTrue(reg.isListed(project));
    }

    // This is a retained, explicit tradeoff of open applications, not project authentication.
    function test_permissionlessApplicantCanOccupySlotUntilRejected() public {
        vm.prank(challenger);
        bytes32 id =
            reg.applyListing(project, "Bogus terms", "https://example.org/x", 100, challenger);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        _apply();
        assertTrue(_answer(id, false));
        assertFalse(reg.isListed(project));
        assertTrue(_answer(_apply(), true));
        assertEq(reg.projectOf(project).beneficiary, beneficiary);
    }

    function test_stakingFaucetTokenCannotPayOracleFee() public {
        address fresh = makeAddr("faucet user");
        TestIMD stakingToken = new TestIMD();
        vm.startPrank(fresh);
        stakingToken.faucet();
        stakingToken.approve(address(reg), 1e18);
        vm.expectRevert();
        reg.applyListing(project, "Project", "https://example.org/x", 50, fresh);
        imd.mint(fresh, reg.ORACLE_FEE());
        imd.approve(address(reg), reg.ORACLE_FEE());
        bytes32 id = reg.applyListing(project, "Project", "https://example.org/x", 50, fresh);
        vm.stopPrank();
        assertTrue(_answer(id, true));
        assertEq(stakingToken.balanceOf(fresh), 10_000e18);
    }
}
