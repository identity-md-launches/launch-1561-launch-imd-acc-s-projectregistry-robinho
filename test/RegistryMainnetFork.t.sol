// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProjectRegistry, IIntake} from "../src/ProjectRegistry.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {OwnedProject} from "./RegistryApplicantGate.t.sol";

/// @dev The mainnet registry exactly as launch.json lists it (IMD, the live mainnet Stacker, a
/// 20 IMD bond, a 7-day cooldown), against a fork of Ethereum with the real Intake v2 and the real
/// IMD: an owner's application really pays the Intake and opens a request with our callback; the
/// answers are played with a test key (the registry here trusts it instead of the oracle's) and
/// delivered with mainnet's 200,000 callback gas. Set ETH_RPC_URL to run it; skipped otherwise.
contract RegistryMainnetForkTest is Test {
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant STACKER = 0x06909F672301F28A810f78cfe7a754851269F4F0;
    uint256 internal constant CALLBACK_GAS = 200_000;
    uint256 internal constant KEY = 0xA11CE;

    ProjectRegistry internal reg;
    address internal teamOwner = makeAddr("teamOwner");
    address internal challenger = makeAddr("challenger");
    address internal project;
    bool internal forked;
    uint256 internal uuid;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        if (block.chainid != 1) return;
        forked = true;
        reg = new ProjectRegistry(INTAKE, IMD, STACKER, vm.addr(KEY), 1, 20e18, 7 days);
        project = address(new OwnedProject(teamOwner));
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? teamOwner : challenger;
            deal(IMD, who, 100e18);
            vm.prank(who);
            IERC20(IMD).approve(address(reg), type(uint256).max);
        }
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function _answer(bytes32 id, bool yes) internal returns (bool ok, uint256 used) {
        OracleAttestation.Attestation memory a;
        a.requestId = bytes32(++uuid << 128);
        a.chainId = 1;
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(yes);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 13;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, reg.attestationDigest(a));
        vm.prank(INTAKE);
        uint256 g = gasleft();
        (ok,) = address(reg).call{gas: CALLBACK_GAS}(
            abi.encodeCall(reg.onOracleResult, (id, a, abi.encodePacked(r, s, v)))
        );
        used = g - gasleft();
    }

    function test_mainnet_ownerAppliesToTheRealIntake_listedThenDefended() public onlyFork {
        uint256 fee = reg.ORACLE_FEE();
        emit log_named_uint("ORACLE_FEE (IMD wei)", fee);
        assertGt(fee, 0, "the Intake sells the question on mainnet");

        // A stranger can't take the owned project's slot; its owner can.
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.NotProjectOwner.selector, teamOwner));
        reg.applyListing(project, "Team", "https://example.org/team", 50, teamOwner);

        uint256 before_ = IERC20(IMD).balanceOf(teamOwner);
        vm.prank(teamOwner);
        bytes32 id = reg.applyListing(project, "Team", "https://example.org/team", 50, teamOwner);
        assertEq(before_ - IERC20(IMD).balanceOf(teamOwner), fee, "the fee went to the Intake");
        assertEq(IERC20(IMD).balanceOf(address(reg)), 0, "the registry keeps nothing");
        (address payer, address target, bytes4 sel, bool completed) = IIntake(INTAKE).requests(id);
        assertEq(payer, address(reg));
        assertEq(target, address(reg));
        assertEq(sel, bytes4(0x510379c7));
        assertFalse(completed);

        (bool ok, uint256 used) = _answer(id, true);
        emit log_named_uint("listing answer gas (200k budget)", used);
        assertTrue(ok, "a listing answer fits mainnet's callback gas");
        assertTrue(reg.isListed(project));

        // After the 7-day cooldown, a challenge pays fee + 20 IMD; a yes pays the bond to the
        // beneficiary in real IMD, still within the callback gas.
        vm.warp(block.timestamp + 7 days);
        vm.prank(challenger);
        bytes32 cid = reg.challengeForBeneficiary(project, "Check the fee guard.", teamOwner);
        assertEq(IERC20(IMD).balanceOf(address(reg)), 20e18, "the bond is held");
        uint256 ownerBefore = IERC20(IMD).balanceOf(teamOwner);
        (ok, used) = _answer(cid, true);
        emit log_named_uint("defended answer gas (200k budget)", used);
        assertTrue(ok, "a defended answer fits mainnet's callback gas");
        assertEq(IERC20(IMD).balanceOf(teamOwner) - ownerBefore, 20e18, "bond to the beneficiary");
        assertEq(IERC20(IMD).balanceOf(address(reg)), 0);
        assertTrue(reg.isListed(project));
    }
}
