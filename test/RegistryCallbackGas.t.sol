// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryBase} from "./ProjectRegistry.t.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";

/// @dev Requests and signatures are prepared in setUp so each test calls the callback with cold
/// contract state, as a later Intake transaction would. The call itself receives exactly 200k gas.
abstract contract RegistryColdCallbackBase is RegistryBase {
    bytes32 internal pending;
    OracleAttestation.Attestation internal signedAnswer;
    bytes internal signature;

    function _prepareAnswer(bool yes) internal {
        signedAnswer = _attestation(yes);
        signature = _sign(signedAnswer, SIGNER_KEY);
    }
}

contract RegistryColdListingTest is RegistryColdCallbackBase {
    function setUp() public override {
        super.setUp();
        pending = _apply();
        _prepareAnswer(true);
    }

    function test_coldApplicationYes_deliveredWithin200k() public {
        assertTrue(intake.deliver(pending, signedAnswer, signature, 200_000));
        assertTrue(reg.isListed(project));
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
    }
}

contract RegistryColdRejectionTest is RegistryColdCallbackBase {
    function setUp() public override {
        super.setUp();
        pending = _apply();
        _prepareAnswer(false);
    }

    function test_coldApplicationNo_deliveredWithin200k() public {
        assertTrue(intake.deliver(pending, signedAnswer, signature, 200_000));
        assertFalse(reg.isListed(project));
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
    }
}

contract RegistryColdDefenseTest is RegistryColdCallbackBase {
    function setUp() public override {
        super.setUp();
        _listed();
        pending = _challenge();
        _prepareAnswer(true);
    }

    function test_coldDefendedChallenge_deliveredWithin200k() public {
        assertTrue(intake.deliver(pending, signedAnswer, signature, 200_000));
        assertTrue(reg.isListed(project));
        assertEq(imd.balanceOf(beneficiary), BOND);
        assertEq(imd.balanceOf(address(reg)), 0);
    }
}

contract RegistryColdDelistingTest is RegistryColdCallbackBase {
    function setUp() public override {
        super.setUp();
        _listed();
        pending = _challenge();
        _prepareAnswer(false);
    }

    function test_coldDelistedChallenge_deliveredWithin200k() public {
        assertTrue(intake.deliver(pending, signedAnswer, signature, 200_000));
        assertFalse(reg.isListed(project));
        assertEq(imd.balanceOf(address(reg)), 0);
        assertEq(imd.balanceOf(challenger), 1_000e18 - 0.5e18);
    }
}

contract RegistryColdFailureTest is RegistryColdCallbackBase {
    function setUp() public override {
        super.setUp();
        _listed();
        pending = _challenge();
    }

    function test_coldRefusedChallenge_deliveredWithin200k() public {
        assertTrue(intake.fail(pending, 1, bytes32("body_refused"), 200_000));
        _assertReturnedBondAndOpenSlot();
    }

    function test_coldDisagreedChallenge_deliveredWithin200k() public {
        assertTrue(intake.fail(pending, 2, bytes32("disagreed"), 200_000));
        _assertReturnedBondAndOpenSlot();
    }

    function test_coldChallengeAfterDeadline_canExpire() public {
        vm.warp(block.timestamp + 1 days + 1);
        reg.expire(project);
        _assertReturnedBondAndOpenSlot();
    }

    function _assertReturnedBondAndOpenSlot() internal view {
        assertTrue(reg.isListed(project));
        assertEq(imd.balanceOf(address(reg)), 0);
        assertEq(imd.balanceOf(challenger), 1_000e18 - 0.5e18);
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
        assertEq(reg.projectOfIntake(pending), address(0));
    }
}
