// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {MockIntake, MintableIMD, MockProject} from "./mocks/MockIntake.sol";

/// @dev Drives the registry through random sequences: applications, challenges, signed yes and no
/// answers, failures, silent completions, expiries, beneficiary changes and time passing. Every
/// call is guarded or wrapped so the handler itself never reverts.
contract RegistryHandler is Test {
    uint256 internal constant SIGNER_KEY = 0xA11CE;

    ProjectRegistry public reg;
    MockIntake public intake;
    MintableIMD public imd;
    address[] public projects;
    address[] public actors;
    uint256 internal uuid;

    uint256 public listings;
    uint256 public delistings;
    uint256 public defended;
    uint256 public cleared;

    constructor(ProjectRegistry reg_, MockIntake intake_, MintableIMD imd_) {
        reg = reg_;
        intake = intake_;
        imd = imd_;
        for (uint256 i; i < 3; ++i) {
            projects.push(address(new MockProject()));
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            imd.mint(a, 1_000_000e18);
            vm.prank(a);
            imd.approve(address(reg), type(uint256).max);
        }
    }

    function projectCount() external view returns (uint256) {
        return projects.length;
    }

    function applyFor(uint256 pSeed, uint256 aSeed, uint16 rate) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (s.ask != ProjectRegistry.Ask.None || s.listed) return;
        rate = uint16(bound(rate, 25, 100));
        vm.prank(actors[aSeed % actors.length]);
        reg.applyListing(
            p,
            "Project",
            "https://example.org/source",
            rate,
            actors[(aSeed % actors.length + 1) % actors.length]
        );
    }

    function challengeFor(uint256 pSeed, uint256 aSeed) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (!s.listed || s.ask != ProjectRegistry.Ask.None) return;
        if (block.timestamp < s.challengeOpenAt) vm.warp(s.challengeOpenAt);
        vm.prank(actors[aSeed % actors.length]);
        reg.challengeForBeneficiary(p, "It breaks the fee guard.", s.beneficiary);
    }

    function answer(uint256 pSeed, bool yes) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (s.ask == ProjectRegistry.Ask.None) return;
        bool wasListed = s.listed;
        OracleAttestation.Attestation memory a;
        a.requestId = bytes32(++uuid << 128);
        a.chainId = 1;
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(yes);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 11;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(SIGNER_KEY, reg.attestationDigest(a));
        bool delivered = intake.deliver(s.intakeId, a, abi.encodePacked(r, sg, v), 200_000);
        if (!delivered) return; // too late: left for expire
        bool nowListed = reg.isListed(p);
        if (!wasListed && nowListed) listings++;
        if (wasListed && !nowListed) delistings++;
        if (wasListed && nowListed) defended++;
    }

    function failFor(uint256 pSeed, bool refused) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (s.ask == ProjectRegistry.Ask.None) return;
        if (intake.fail(
                s.intakeId,
                refused ? 1 : 2,
                refused ? bytes32("refused") : bytes32("disagreed"),
                200_000
            )) {
            cleared++;
        }
    }

    function completeAndExpire(uint256 pSeed) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (s.ask == ProjectRegistry.Ask.None) return;
        intake.completeSilently(s.intakeId);
        reg.expire(p);
        cleared++;
    }

    function passTime(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
        vm.roll(block.number + 1 + (secs % 50));
    }

    function expireStale(uint256 pSeed) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (
            s.ask == ProjectRegistry.Ask.None
                || block.timestamp <= uint256(s.askedAt) + reg.PENDING_EXPIRY()
        ) return;
        reg.expire(p);
        cleared++;
    }

    function handOver(uint256 pSeed, uint256 aSeed) external {
        address p = projects[pSeed % projects.length];
        ProjectRegistry.Project memory s = reg.projectOf(p);
        if (!s.listed || s.ask != ProjectRegistry.Ask.None) return;
        address next = actors[aSeed % actors.length];
        uint64 openAt = reg.handoffOpenAt(p);
        vm.prank(s.beneficiary);
        if (next != s.beneficiary && block.timestamp < openAt) {
            vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.HandoffTooSoon.selector, openAt));
        }
        reg.setBeneficiary(p, next);
    }
}

contract ProjectRegistryInvariantTest is StdInvariant, Test {
    uint256 internal constant BOND = 5e18;
    RegistryHandler internal handler;
    ProjectRegistry internal reg;
    MockIntake internal intake;
    MintableIMD internal imd;

    function setUp() public {
        vm.roll(1_000);
        vm.warp(1_700_000_000);
        intake = new MockIntake();
        imd = new MintableIMD();
        reg = new ProjectRegistry(
            address(intake), address(imd), address(0x57AC), vm.addr(0xA11CE), 1, BOND, 1 hours
        );
        handler = new RegistryHandler(reg, intake, imd);
        targetContract(address(handler));
    }

    /// @notice The registry holds exactly the bonds of the open challenges, and never keeps an
    /// approval to the Intake.
    function invariant_holdsOnlyOpenBonds() public view {
        uint256 open;
        for (uint256 i; i < handler.projectCount(); ++i) {
            if (reg.projectOf(handler.projects(i)).ask == ProjectRegistry.Ask.Challenge) open++;
        }
        assertEq(imd.balanceOf(address(reg)), open * BOND, "bonds held");
        assertEq(imd.allowance(address(reg), address(intake)), 0, "no leftover approval");
    }

    /// @notice Each project's record is consistent with its open question and its listing.
    function invariant_recordsConsistent() public view {
        for (uint256 i; i < handler.projectCount(); ++i) {
            address p = handler.projects(i);
            ProjectRegistry.Project memory s = reg.projectOf(p);
            if (s.ask == ProjectRegistry.Ask.None) {
                assertEq(s.intakeId, bytes32(0), "no question, no id");
                assertEq(s.asker, address(0), "no question, no asker");
            } else {
                assertEq(reg.projectOfIntake(s.intakeId), p, "open id maps back");
                assertTrue(s.asker != address(0));
                if (s.ask == ProjectRegistry.Ask.Apply) {
                    assertFalse(s.listed, "apply only when not listed");
                } else {
                    assertTrue(s.listed, "challenge only when listed");
                }
            }
            if (s.listed) {
                assertGt(s.fromBlock, 0);
                assertEq(s.toBlock, 0, "listed has no end");
                assertGe(s.rateBps, 25);
                assertLe(s.rateBps, 100);
                assertTrue(s.beneficiary != address(0));
            }
            if (s.toBlock != 0) assertGe(s.toBlock, s.fromBlock, "periods run forward");
        }
    }

    /// @notice A fixed path through the handler that reaches a listing, a defended challenge, a
    /// delisting, a failure and an expiry, so the random campaign is known to reach them too.
    function test_handlerReachesEveryOutcome() public {
        handler.applyFor(0, 0, 50);
        handler.answer(0, true);
        assertEq(handler.listings(), 1);
        handler.challengeFor(0, 1);
        handler.answer(0, true);
        assertEq(handler.defended(), 1);
        handler.challengeFor(0, 2);
        handler.failFor(0, false);
        handler.challengeFor(0, 2);
        handler.answer(0, false);
        assertEq(handler.delistings(), 1);
        handler.applyFor(1, 0, 25);
        handler.completeAndExpire(1);
        handler.applyFor(2, 0, 100);
        handler.passTime(2 days);
        handler.expireStale(2);
        assertEq(handler.cleared(), 3);
        invariant_holdsOnlyOpenBonds();
        invariant_recordsConsistent();
        invariant_listingCounts();
    }

    /// @notice Only a signed answer changes a listing: delistings never outnumber listings.
    function invariant_listingCounts() public view {
        uint256 listedNow;
        for (uint256 i; i < handler.projectCount(); ++i) {
            if (reg.isListed(handler.projects(i))) listedNow++;
        }
        assertEq(handler.listings() - handler.delistings(), listedNow, "listings minus delistings");
    }
}
