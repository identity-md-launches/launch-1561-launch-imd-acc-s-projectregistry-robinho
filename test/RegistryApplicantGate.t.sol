// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryBase} from "./ProjectRegistry.t.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {MockProject} from "./mocks/MockIntake.sol";

/// @dev A project that reports an owner and can apply for itself.
contract OwnedProject {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function applySelf(ProjectRegistry reg, address imd, address beneficiary)
        external
        returns (bytes32)
    {
        (bool ok,) = imd.call(
            abi.encodeWithSignature("approve(address,uint256)", address(reg), type(uint256).max)
        );
        require(ok);
        return reg.applyListing(address(this), "Self", "https://example.org/self", 50, beneficiary);
    }
}

/// @dev `owner()` that misbehaves in each of the ways the registry must treat as "no owner".
contract OddOwner {
    uint256 internal immutable mode; // 1 revert, 2 burn gas, 3 64-byte answer, 4 dirty upper bits, 5 empty answer

    constructor(uint256 mode_) {
        mode = mode_;
    }

    fallback() external {
        uint256 m = mode;
        if (m == 1) revert("no owner");
        if (m == 2) {
            while (true) {}
        }
        if (m == 3) {
            assembly ("memory-safe") {
                mstore(0, 0xbeef)
                mstore(32, 0xbeef)
                return(0, 64)
            }
        }
        if (m == 4) {
            assembly ("memory-safe") {
                mstore(0, not(0))
                return(0, 32)
            }
        }
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

contract RegistryApplicantGateTest is RegistryBase {
    address internal teamOwner = makeAddr("teamOwner");
    address internal squatter = makeAddr("squatter");

    function setUp() public override {
        super.setUp();
        _fund(teamOwner);
        _fund(squatter);
    }

    function _applyAs(address who, address p) internal returns (bytes32) {
        vm.prank(who);
        return reg.applyListing(p, "Team", "https://example.org/team", 50, beneficiary);
    }

    // ───────────────────────── projects that report an owner ─────────────────────────

    function test_ownerMayApply() public {
        address owned = address(new OwnedProject(teamOwner));
        assertEq(reg.projectOwner(owned), teamOwner);
        _applyAs(teamOwner, owned);
        assertEq(uint8(reg.projectOf(owned).ask), uint8(ProjectRegistry.Ask.Apply));
    }

    function test_projectItselfMayApply() public {
        OwnedProject owned = new OwnedProject(teamOwner);
        imd.mint(address(owned), 1e18);
        owned.applySelf(reg, address(imd), beneficiary);
        assertEq(reg.projectOf(address(owned)).asker, address(owned));
    }

    function test_strangerRefusedBeforePaying() public {
        address owned = address(new OwnedProject(teamOwner));
        uint256 before_ = imd.balanceOf(squatter);
        vm.prank(squatter);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.NotProjectOwner.selector, teamOwner));
        reg.applyListing(owned, "squat", "https://example.invalid", 25, squatter);
        assertEq(imd.balanceOf(squatter), before_, "no fee taken");
        assertEq(uint8(reg.projectOf(owned).ask), uint8(ProjectRegistry.Ask.None));
    }

    /// @dev The squatting IMD's audit reproduced (launch #1409): a stranger can no longer hold an
    /// owned project's question slot, so its team always gets its application in.
    function test_squatterCannotBlockTheTeam() public {
        address owned = address(new OwnedProject(teamOwner));
        for (uint256 i; i < 3; ++i) {
            vm.prank(squatter);
            vm.expectRevert(
                abi.encodeWithSelector(ProjectRegistry.NotProjectOwner.selector, teamOwner)
            );
            reg.applyListing(owned, "squat", "https://example.invalid", 25, squatter);
        }
        bytes32 id = _applyAs(teamOwner, owned);
        project = owned;
        assertTrue(_answer(id, true));
        assertTrue(reg.isListed(owned));
    }

    function test_ownerChangeMovesTheRight() public {
        OwnedProject owned = new OwnedProject(teamOwner);
        address next = makeAddr("next");
        _fund(next);
        vm.store(address(owned), bytes32(0), bytes32(uint256(uint160(next))));
        vm.prank(teamOwner);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.NotProjectOwner.selector, next));
        reg.applyListing(address(owned), "Team", "https://example.org/team", 50, beneficiary);
        _applyAs(next, address(owned));
    }

    // ───────────────────────── projects without one: open to anyone ─────────────────────────

    function test_noOwnerFunctionOpenToAnyone() public {
        address plain = address(new MockProject());
        assertEq(reg.projectOwner(plain), address(0));
        _applyAs(squatter, plain);
    }

    function test_renouncedOwnerOpenToAnyone() public {
        address renounced = address(new OwnedProject(address(0)));
        assertEq(reg.projectOwner(renounced), address(0));
        _applyAs(squatter, renounced);
    }

    function test_misbehavingOwnerReadsAsNone() public {
        for (uint256 m = 1; m <= 5; ++m) {
            address odd = address(new OddOwner(m));
            uint256 g = gasleft();
            assertEq(reg.projectOwner(odd), address(0), "treated as no owner");
            assertLt(g - gasleft(), reg.OWNER_CALL_GAS() + 10_000, "bounded gas");
            _applyAs(squatter, odd);
        }
    }

    // ───────────────────────── challenges stay open to anyone ─────────────────────────

    function test_anyoneMayStillChallengeAnOwnedProject() public {
        address owned = address(new OwnedProject(teamOwner));
        bytes32 id = _applyAs(teamOwner, owned);
        project = owned;
        assertTrue(_answer(id, true));
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(squatter);
        reg.challengeForBeneficiary(owned, "It credits wallets outside trades.", beneficiary);
        assertEq(uint8(reg.projectOf(owned).ask), uint8(ProjectRegistry.Ask.Challenge));
    }
}
