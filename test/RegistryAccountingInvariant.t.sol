// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ProjectRegistry} from "src/ProjectRegistry.sol";
import {OracleAttestation} from "src/oracle/OracleAttestation.sol";
import {MockIntake, MintableIMD, MockProject} from "./mocks/MockIntake.sol";

/// @dev The expected ledger is driven by inputs and signed outcomes, never by observed payouts.
/// A wrong recipient can preserve total token supply and registry solvency, but fails this model.
contract RegistryAccountingHandler is Test {
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    uint256 public constant INITIAL_FUNDS = 1_000_000e18;
    uint256 public constant BOND = 5e18;
    uint256 public constant ACTOR_COUNT = 5;
    uint256 public constant PROJECT_COUNT = 3;

    struct Model {
        bool listed;
        bool pinRequired;
        ProjectRegistry.Ask ask;
        address beneficiary;
        address asker;
        uint16 rate;
        uint64 askedAt;
        uint64 fromBlock;
        uint64 toBlock;
        uint64 challengeOpenAt;
        uint64 handoffOpenAt;
        bytes32 requestId;
    }

    ProjectRegistry public immutable reg;
    MockIntake public immutable intake;
    MintableIMD public immutable imd;
    address[5] public actors;
    address[3] public projects;
    Model[3] internal models;
    mapping(address => uint256) public expectedFunds;
    bytes32[] internal requests;
    mapping(bytes32 => address) internal expectedRequestProject;

    uint256 public fee = 0.5e18;
    uint256 public paidFees;
    uint256 public openBonds;
    uint256 public donated;
    uint256 public oracleNonce;
    uint256 public applications;
    uint256 public challenges;
    uint256 public listed;
    uint256 public rejected;
    uint256 public defended;
    uint256 public delisted;
    uint256 public failures;
    uint256 public expiries;
    uint256 public invalidAttempts;
    uint256 public retiredAttempts;
    uint256 public lockedHandovers;
    uint256 public pacedHandovers;
    uint256 public unsafeChallengeAttempts;

    constructor(ProjectRegistry reg_, MockIntake intake_, MintableIMD imd_) {
        reg = reg_;
        intake = intake_;
        imd = imd_;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            actors[i] = makeAddr(string.concat("accounting actor ", vm.toString(i)));
            imd.mint(actors[i], INITIAL_FUNDS);
            expectedFunds[actors[i]] = INITIAL_FUNDS;
        }
        for (uint256 i; i < PROJECT_COUNT; ++i) {
            projects[i] = address(new MockProject());
        }
    }

    function ask(uint256 pSeed, uint256 aSeed, uint256 bSeed, uint16 rawRate) external {
        uint256 pIndex = pSeed % PROJECT_COUNT;
        Model storage m = models[pIndex];
        if (m.ask != ProjectRegistry.Ask.None) return;
        address actor = actors[aSeed % ACTOR_COUNT];
        address beneficiary = actors[bSeed % ACTOR_COUNT];
        address project = projects[pIndex];
        uint16 rate = uint16(bound(rawRate, 25, 100));
        if (m.listed && block.timestamp < m.challengeOpenAt) vm.warp(m.challengeOpenAt);
        if (fee == 0) {
            vm.prank(actor);
            vm.expectRevert(ProjectRegistry.OracleUnavailable.selector);
            if (m.listed) {
                reg.challengeForBeneficiary(project, "Check the trading fees.", m.beneficiary);
            } else {
                reg.applyListing(
                    project, "Project", "https://example.org/source", rate, beneficiary
                );
            }
            retiredAttempts++;
            return;
        }

        uint256 payment = fee + (m.listed ? BOND : 0);
        // Fixed initial supply is ample even if one actor pays every request in a campaign.
        assertGe(expectedFunds[actor], payment, "harness funding exhausted");
        vm.startPrank(actor);
        imd.approve(address(reg), payment);
        bytes32 id;
        if (m.listed) {
            id = reg.challengeForBeneficiary(project, "Check the trading fees.", m.beneficiary);
        } else {
            id = reg.applyListing(
                project, "Project", "https://example.org/source", rate, beneficiary
            );
        }
        vm.stopPrank();

        expectedFunds[actor] -= payment;
        paidFees += fee;
        if (m.listed) {
            m.ask = ProjectRegistry.Ask.Challenge;
            openBonds += BOND;
            challenges++;
        } else {
            m.ask = ProjectRegistry.Ask.Apply;
            m.beneficiary = beneficiary;
            m.rate = rate;
            applications++;
        }
        m.askedAt = uint64(block.timestamp);
        m.asker = actor;
        m.requestId = id;
        assertNotEq(id, bytes32(0));
        assertEq(expectedRequestProject[id], address(0), "duplicate live request id");
        requests.push(id);
        expectedRequestProject[id] = project;
    }

    /// @dev 0=yes, 1=no, 2=body refused, 3=panel disagreement, 4=lost callback then expire.
    function settle(uint256 pSeed, uint8 rawOutcome) external {
        uint256 pIndex = pSeed % PROJECT_COUNT;
        Model storage m = models[pIndex];
        if (m.ask == ProjectRegistry.Ask.None) return;
        uint256 outcome = bound(rawOutcome, 0, 4);
        if (outcome < 2) {
            OracleAttestation.Attestation memory a = _attestation(outcome == 0);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, reg.attestationDigest(a));
            bool delivered = intake.deliver(m.requestId, a, abi.encodePacked(r, s, v), 200_000);
            if (block.timestamp > uint256(m.askedAt) + 1 days) {
                assertFalse(delivered, "late answer accepted");
                reg.expire(projects[pIndex]);
                _refund(m);
                expiries++;
            } else {
                assertTrue(delivered, "valid answer unexpectedly failed");
                if (m.ask == ProjectRegistry.Ask.Apply) {
                    if (outcome == 0) {
                        m.listed = true;
                        m.fromBlock = uint64(block.number);
                        m.toBlock = 0;
                        m.challengeOpenAt = uint64(block.timestamp + 1 hours);
                        listed++;
                    } else {
                        rejected++;
                    }
                } else {
                    openBonds -= BOND;
                    if (outcome == 0) {
                        expectedFunds[m.beneficiary] += BOND;
                        defended++;
                    } else {
                        expectedFunds[m.asker] += BOND;
                        m.listed = false;
                        m.toBlock = uint64(block.number);
                        delisted++;
                    }
                }
            }
        } else if (outcome < 4) {
            assertTrue(
                intake.fail(
                    m.requestId,
                    outcome == 2 ? 1 : 2,
                    outcome == 2 ? bytes32("body_refused") : bytes32("disagreed"),
                    200_000
                ),
                "valid failure callback unexpectedly failed"
            );
            _refund(m);
            failures++;
        } else {
            intake.completeSilently(m.requestId);
            // An unrelated caller can recover a bond, but never receives it.
            vm.prank(actors[(pIndex + 1) % ACTOR_COUNT]);
            reg.expire(projects[pIndex]);
            _refund(m);
            expiries++;
        }
        _close(m);
    }

    function expire(uint256 pSeed, uint256 aSeed) external {
        uint256 pIndex = pSeed % PROJECT_COUNT;
        Model storage m = models[pIndex];
        if (m.ask == ProjectRegistry.Ask.None) return;
        uint256 afterDeadline = uint256(m.askedAt) + 1 days + 1;
        if (block.timestamp < afterDeadline) vm.warp(afterDeadline);
        vm.prank(actors[aSeed % ACTOR_COUNT]);
        reg.expire(projects[pIndex]);
        _refund(m);
        _close(m);
        expiries++;
    }

    function handOver(uint256 pSeed, uint256 aSeed) external {
        uint256 pIndex = pSeed % PROJECT_COUNT;
        Model storage m = models[pIndex];
        if (!m.listed) return;
        address next = actors[aSeed % ACTOR_COUNT];
        vm.prank(m.beneficiary);
        if (m.ask != ProjectRegistry.Ask.None) {
            vm.expectRevert(ProjectRegistry.AskOpen.selector);
            reg.setBeneficiary(projects[pIndex], next);
            lockedHandovers++;
            return;
        }
        if (next != m.beneficiary && block.timestamp < m.handoffOpenAt) {
            vm.expectRevert(
                abi.encodeWithSelector(ProjectRegistry.HandoffTooSoon.selector, m.handoffOpenAt)
            );
            reg.setBeneficiary(projects[pIndex], next);
            pacedHandovers++;
            return;
        }
        reg.setBeneficiary(projects[pIndex], next);
        if (next != m.beneficiary) {
            m.pinRequired = true;
            m.handoffOpenAt = uint64(block.timestamp + 1 days);
        }
        m.beneficiary = next;
    }

    /// @dev Exercise rejected calls too: neither a stale pin nor the legacy API may buy a
    /// question about an unintended wallet. The ledger and request model must stay unchanged.
    function unsafeChallenge(uint256 pSeed, uint256 aSeed) external {
        uint256 pIndex = pSeed % PROJECT_COUNT;
        Model storage m = models[pIndex];
        if (!m.listed || m.ask != ProjectRegistry.Ask.None) return;
        if (block.timestamp < m.challengeOpenAt) vm.warp(m.challengeOpenAt);
        address wrongBeneficiary = actors[0] == m.beneficiary ? actors[1] : actors[0];
        vm.prank(actors[aSeed % ACTOR_COUNT]);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProjectRegistry.BeneficiaryChanged.selector, wrongBeneficiary, m.beneficiary
            )
        );
        reg.challengeForBeneficiary(projects[pIndex], "Review this wallet.", wrongBeneficiary);
        unsafeChallengeAttempts++;
        if (m.pinRequired) {
            vm.prank(actors[aSeed % ACTOR_COUNT]);
            vm.expectRevert(ProjectRegistry.BeneficiaryPinRequired.selector);
            reg.challenge(projects[pIndex], "Review this wallet.");
            unsafeChallengeAttempts++;
        }
    }

    function donate(uint256 aSeed, uint96 rawAmount) external {
        address actor = actors[aSeed % ACTOR_COUNT];
        uint256 amount = bound(rawAmount, 1, 1e18);
        vm.prank(actor);
        imd.transfer(address(reg), amount);
        expectedFunds[actor] -= amount;
        donated += amount;
    }

    function reprice(uint96 rawPrice) external {
        fee = bound(rawPrice, 0, 2e18);
        intake.setPrice(fee);
    }

    function passTime(uint32 rawSeconds, uint8 rawBlocks) external {
        vm.warp(block.timestamp + bound(rawSeconds, 0, 2 days));
        vm.roll(block.number + bound(rawBlocks, 1, 64));
    }

    function unauthorizedOrReplay(uint256 pSeed, uint256 rSeed) external {
        uint256 pIndex = pSeed % PROJECT_COUNT;
        Model storage m = models[pIndex];
        address outsider = actors[0] == m.beneficiary ? actors[1] : actors[0];
        vm.prank(outsider);
        vm.expectRevert(
            !m.listed
                ? ProjectRegistry.NotListed.selector
                : m.ask != ProjectRegistry.Ask.None
                    ? ProjectRegistry.AskOpen.selector
                    : ProjectRegistry.NotBeneficiary.selector
        );
        reg.setBeneficiary(projects[pIndex], outsider);
        invalidAttempts++;
        if (requests.length == 0) return;
        bytes32 id = requests[rSeed % requests.length];
        OracleAttestation.Attestation memory a = _attestation(true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, reg.attestationDigest(a));
        if (expectedRequestProject[id] == address(0)) {
            vm.prank(address(intake));
            vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, id));
            reg.onOracleResult(id, a, abi.encodePacked(r, s, v));
            vm.prank(address(intake));
            vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, id));
            reg.onOracleFailure(id, 2, "disagreed", 0, 0, "");
        } else {
            vm.prank(outsider);
            vm.expectRevert(ProjectRegistry.NotIntake.selector);
            reg.onOracleResult(id, a, abi.encodePacked(r, s, v));
            vm.prank(outsider);
            vm.expectRevert(ProjectRegistry.NotIntake.selector);
            reg.onOracleFailure(id, 1, "body_invalid", 0, 0, "");
        }
        invalidAttempts += 2;
    }

    function _attestation(bool yes) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = bytes32(++oracleNonce << 128);
        a.chainId = 1;
        a.questionHash = keccak256(abi.encode(oracleNonce));
        a.answer = abi.encode(yes);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 11;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _refund(Model storage m) internal {
        if (m.ask == ProjectRegistry.Ask.Challenge) {
            expectedFunds[m.asker] += BOND;
            openBonds -= BOND;
        }
    }

    function _close(Model storage m) internal {
        delete expectedRequestProject[m.requestId];
        m.requestId = bytes32(0);
        m.ask = ProjectRegistry.Ask.None;
        m.asker = address(0);
    }

    function assertAccounting() external view {
        uint256 balances = imd.balanceOf(address(reg)) + imd.balanceOf(intake.TREASURY());
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            assertEq(
                imd.balanceOf(actors[i]), expectedFunds[actors[i]], "actor fee/bond entitlement"
            );
            assertEq(
                imd.allowance(actors[i], address(reg)), 0, "exact user payment approval consumed"
            );
            balances += imd.balanceOf(actors[i]);
        }
        assertEq(imd.balanceOf(intake.TREASURY()), paidFees, "only oracle fees reach treasury");
        assertEq(imd.balanceOf(address(reg)), openBonds + donated, "bonds plus unsolicited tokens");
        assertEq(imd.allowance(address(reg), address(intake)), 0, "Intake cannot take another bond");
        assertEq(imd.balanceOf(address(intake)), 0);
        assertEq(imd.totalSupply(), ACTOR_COUNT * INITIAL_FUNDS, "no minting during the campaign");
        assertEq(balances, imd.totalSupply(), "every token has a tracked holder");
    }

    function assertStateMachine() external view {
        uint256 listedNow;
        uint256 pendingChallenges;
        for (uint256 i; i < PROJECT_COUNT; ++i) {
            Model memory m = models[i];
            ProjectRegistry.Project memory actual = reg.projectOf(projects[i]);
            assertEq(actual.listed, m.listed, "listing changes only on the intended answer");
            assertEq(uint8(actual.ask), uint8(m.ask), "pending state");
            assertEq(actual.asker, m.asker, "payer retained until settlement");
            assertEq(actual.beneficiary, m.beneficiary, "beneficiary authorization");
            assertEq(
                reg.beneficiaryPinRequired(projects[i]), m.pinRequired, "handoff pin is permanent"
            );
            assertEq(reg.handoffOpenAt(projects[i]), m.handoffOpenAt, "one handoff per interval");
            assertEq(actual.rateBps, m.rate, "stated rate");
            assertEq(actual.askedAt, m.askedAt, "request timestamp");
            assertEq(actual.fromBlock, m.fromBlock, "listing start");
            assertEq(actual.toBlock, m.toBlock, "listing end");
            assertEq(actual.challengeOpenAt, m.challengeOpenAt, "defense must not renew immunity");
            assertEq(actual.intakeId, m.requestId, "only the current request may settle");
            if (m.listed) listedNow++;
            if (m.ask == ProjectRegistry.Ask.Challenge) pendingChallenges++;
        }
        for (uint256 i; i < requests.length; ++i) {
            assertEq(
                reg.projectOfIntake(requests[i]),
                expectedRequestProject[requests[i]],
                "request consumed once"
            );
        }
        assertEq(listedNow + delisted, listed, "listing history");
        assertEq(openBonds, pendingChallenges * BOND, "one bond per pending challenge");
        assertEq(intake.count(), applications + challenges, "one paid request per accepted ask");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RegistryAccountingInvariantTest is StdInvariant, Test {
    RegistryAccountingHandler internal handler;

    function setUp() public {
        vm.chainId(11155111);
        vm.roll(1_000);
        vm.warp(1_700_000_000);
        MockIntake intake = new MockIntake();
        MintableIMD imd = new MintableIMD();
        ProjectRegistry reg = new ProjectRegistry(
            address(intake),
            address(imd),
            address(new MockProject()),
            vm.addr(0xA11CE),
            1,
            5e18,
            1 hours
        );
        handler = new RegistryAccountingHandler(reg, intake, imd);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.ask.selector;
        selectors[1] = handler.settle.selector;
        selectors[2] = handler.expire.selector;
        selectors[3] = handler.handOver.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.reprice.selector;
        selectors[6] = handler.passTime.selector;
        selectors[7] = handler.unauthorizedOrReplay.selector;
        selectors[8] = handler.unsafeChallenge.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_eachActorGetsExactlyTheirEntitlement() public view {
        handler.assertAccounting();
    }

    function invariant_requestsAndListingsMatchIndependentHistory() public view {
        handler.assertStateMachine();
    }

    /// @dev Every remaining bond must be recoverable after an arbitrary call sequence.
    function afterInvariant() public {
        for (uint256 i; i < 3; ++i) {
            handler.expire(i, 4);
        }
        assertEq(handler.openBonds(), 0, "no orphaned bonds after draining");
        handler.assertAccounting();
        handler.assertStateMachine();
    }

    function test_handlerReachesAllPayoutsAndChecksAfterEachTransition() public {
        handler.ask(0, 0, 1, 25);
        _check();
        handler.settle(0, 1); // rejected application
        _check();
        handler.ask(0, 0, 1, 100);
        handler.settle(0, 0); // list
        _check();
        handler.ask(0, 2, 3, 50); // challenge; attempted new terms are irrelevant
        handler.handOver(0, 4); // must reject while the bond's recipient is locked
        handler.unauthorizedOrReplay(0, 2); // AskOpen also precedes caller authorization
        _check();
        handler.settle(0, 0); // defend: current beneficiary gets bond
        _check();
        handler.handOver(0, 4); // handoff becomes available after settlement
        _check();
        handler.ask(0, 4, 4, 50); // beneficiary can also be challenger
        handler.settle(0, 1); // delist: same actor gets refund
        _check();
        handler.ask(1, 1, 2, 50);
        handler.settle(1, 0);
        handler.ask(1, 3, 0, 50);
        handler.settle(1, 2); // refused challenge
        _check();
        handler.ask(1, 3, 0, 50);
        handler.settle(1, 3); // split panel
        _check();
        handler.ask(1, 3, 0, 50);
        handler.settle(1, 4); // callback lost
        _check();
        handler.ask(1, 3, 0, 50);
        handler.passTime(2 days, 1);
        handler.settle(1, 0); // valid signature, but too late
        _check();
        handler.ask(1, 2, 0, 50);
        handler.expire(1, 0); // explicit timeout refund
        handler.donate(2, 123);
        handler.reprice(0);
        handler.ask(2, 0, 1, 50); // retired action must move nothing
        handler.reprice(1); // one-wei fee, independent of bond
        handler.ask(2, 0, 1, 50);
        handler.unauthorizedOrReplay(1, 0); // settled id
        handler.unauthorizedOrReplay(2, 10); // live id
        _check();
        assertEq(handler.rejected(), 1);
        assertEq(handler.listed(), 2);
        assertEq(handler.defended(), 1);
        assertEq(handler.delisted(), 1);
        assertEq(handler.failures(), 2);
        assertEq(handler.expiries(), 3);
        assertEq(handler.retiredAttempts(), 1);
        assertEq(handler.invalidAttempts(), 9);
        assertEq(handler.lockedHandovers(), 1);
        afterInvariant();
    }

    function test_handlerRetainsBeneficiaryPinAcrossHandoffsAndRelisting() public {
        handler.ask(0, 0, 1, 50);
        handler.settle(0, 0);
        handler.handOver(0, 1); // a no-op is not a handoff
        handler.unsafeChallenge(0, 2);
        assertEq(handler.unsafeChallengeAttempts(), 1);
        _check();

        handler.handOver(0, 4);
        handler.unsafeChallenge(0, 2);
        _check();
        handler.reprice(0);
        handler.ask(0, 2, 0, 50); // pinned API still reports an unavailable oracle
        assertEq(handler.retiredAttempts(), 1);
        _check();
        handler.reprice(0.5e18);
        handler.handOver(0, 1); // too soon after the last handoff: refused, model unchanged
        assertEq(handler.pacedHandovers(), 1);
        _check();
        handler.passTime(1 days, 1);
        handler.handOver(0, 1); // restoring the original wallet cannot clear the pin
        handler.unsafeChallenge(0, 2);
        _check();

        handler.ask(0, 2, 0, 50);
        handler.settle(0, 1); // delist
        _check();
        handler.ask(0, 0, 1, 100);
        handler.settle(0, 0); // relist with the original beneficiary
        handler.unsafeChallenge(0, 2);
        assertEq(handler.unsafeChallengeAttempts(), 7);
        _check();
        handler.ask(0, 2, 0, 50);
        handler.settle(0, 0); // the pinned API remains usable
        _check();
        afterInvariant();
    }

    function _check() internal view {
        handler.assertAccounting();
        handler.assertStateMachine();
    }
}
