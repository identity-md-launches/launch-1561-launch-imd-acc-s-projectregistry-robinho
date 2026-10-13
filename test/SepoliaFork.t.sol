// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestIMD} from "./mocks/TestIMD.sol";
import {TestSIMD} from "./mocks/TestSIMD.sol";
import {Stacker, IStakedIMD} from "../src/Stacker.sol";

/// @dev Runs against a fork of Sepolia with the live TestIMD and TestSIMD of launch #1129, the pair
/// the `sepolia` branch's launch.json wires the Stacker to. Set SEPOLIA_RPC_URL to run it (for example
/// `SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --mc SepoliaFork`); without
/// it every test is skipped.
contract SepoliaForkTest is Test {
    TestIMD internal constant IMD = TestIMD(0x2B69099E59b05901faA1DD164fabf098bf831E82);
    TestSIMD internal constant SIMD = TestSIMD(0xF9e2EEc3B610ec6781f7438aC5Fb4bc049d81Cc1);
    address internal constant VAULT_OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;
    /// @dev Test run 2's live Stacker (launch #1294), which PLEA's hook credits through and test
    /// run 3's registry names.
    address internal constant LIVE_STACKER = 0x0457276D7b036818B3EddC1A4A3FCeda61e9314d;

    Stacker internal stacker;
    address internal project = makeAddr("project");
    address internal trader = makeAddr("trader");
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        if (block.chainid != 11_155_111) return; // another network's RPC: skip rather than fail
        forked = true;
        stacker = new Stacker(IERC20(address(IMD)), IStakedIMD(address(SIMD)));
        vm.prank(project);
        IMD.faucet(); // 10,000 tIMD, as any project would get on Sepolia
        vm.prank(project);
        IMD.approve(address(stacker), type(uint256).max);
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_sepolia_liveFacts() public onlyFork {
        assertEq(SIMD.asset(), address(IMD));
        assertEq(SIMD.owner(), VAULT_OWNER);
        assertEq(
            IMD.allowance(address(stacker), address(SIMD)), 0, "approval deferred to first credit"
        );
    }

    /// @dev The mainnet audit added recipient validation, so byte-for-byte equality with #1294
    /// is no longer expected. Compare valid credits from the same vault state instead.
    function test_sepolia_liveStackerValidCreditMatchesMainnetCandidate() public onlyFork {
        Stacker live = Stacker(LIVE_STACKER);
        assertEq(address(live.IMD()), address(IMD));
        assertEq(address(live.SIMD()), address(SIMD));
        uint256 previousTotal = live.totalStacked();
        uint256 previousProject = live.projectStacked(project);
        uint256 previousShares = live.projectShares(project);
        uint256 checkpoint = vm.snapshotState();
        vm.prank(project);
        uint256 candidateShares = stacker.credit(trader, 1e18);
        uint256 candidateBalance = SIMD.balanceOf(trader);
        uint256 candidateAssets = SIMD.totalAssets();
        assertTrue(vm.revertToStateAndDelete(checkpoint));

        vm.startPrank(project);
        IMD.approve(LIVE_STACKER, type(uint256).max);
        uint256 liveShares = live.credit(trader, 1e18);
        vm.stopPrank();
        assertEq(liveShares, candidateShares);
        assertEq(SIMD.balanceOf(trader), candidateBalance);
        assertEq(SIMD.totalAssets(), candidateAssets);
        assertEq(live.totalStacked() - previousTotal, 1e18);
        assertEq(live.projectStacked(project) - previousProject, 1e18);
        assertEq(live.projectShares(project) - previousShares, candidateShares);
    }

    function test_sepolia_mainnetCandidateRejectsLegacyUnreachableRecipients() public onlyFork {
        uint256 beforeStacker = SIMD.balanceOf(LIVE_STACKER);
        uint256 beforeVault = SIMD.balanceOf(address(SIMD));
        vm.startPrank(project);
        IMD.approve(LIVE_STACKER, type(uint256).max);
        uint256 stuckAtStacker = Stacker(LIVE_STACKER).credit(LIVE_STACKER, 1e18);
        uint256 stuckAtVault = Stacker(LIVE_STACKER).credit(address(SIMD), 1e18);
        vm.expectRevert(Stacker.InvalidTrader.selector);
        stacker.credit(address(stacker), 1e18);
        vm.expectRevert(Stacker.InvalidTrader.selector);
        stacker.credit(address(SIMD), 1e18);
        vm.stopPrank();
        assertGt(stuckAtStacker, 0);
        assertGt(stuckAtVault, 0);
        assertEq(SIMD.balanceOf(LIVE_STACKER), beforeStacker + stuckAtStacker);
        assertEq(SIMD.balanceOf(address(SIMD)), beforeVault + stuckAtVault);
        assertEq(SIMD.balanceOf(address(stacker)), 0);
        assertEq(stacker.totalStacked(), 0);
        assertEq(IMD.balanceOf(project), 10_000e18 - 2e18);
        assertEq(IMD.allowance(address(stacker), address(SIMD)), 0);
    }

    function test_sepolia_creditEventAndTotals() public onlyFork {
        uint256 preview = SIMD.previewDeposit(5e18);
        vm.recordLogs();
        vm.prank(project);
        uint256 shares = stacker.credit(trader, 5e18);
        assertEq(shares, preview);
        assertEq(SIMD.balanceOf(trader), shares);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.emitter, address(stacker));
        assertEq(address(uint160(uint256(last.topics[1]))), project);
        assertEq(address(uint160(uint256(last.topics[2]))), trader);
        (uint256 evImd, uint256 evShares) = abi.decode(last.data, (uint256, uint256));
        assertEq(evImd, 5e18);
        assertEq(evShares, shares);
        assertEq(stacker.projectStacked(project), 5e18);
        assertEq(stacker.totalStacked(), 5e18);
        assertEq(IMD.balanceOf(address(stacker)), 0);
        assertEq(SIMD.balanceOf(address(stacker)), 0);
    }

    /// @dev The fallback integrators must handle: the vault's owner pauses it, `credit` reverts and
    /// moves nothing; after unpausing, credits work again.
    function test_sepolia_pausedVaultRevertsThenRecovers() public onlyFork {
        vm.prank(VAULT_OWNER);
        SIMD.setPaused(true);
        uint256 before = IMD.balanceOf(project);
        vm.prank(project);
        vm.expectRevert();
        stacker.credit(trader, 1e18);
        assertEq(IMD.balanceOf(project), before, "nothing moved");

        vm.prank(VAULT_OWNER);
        SIMD.setPaused(false);
        vm.prank(project);
        assertGt(stacker.credit(trader, 1e18), 0);
    }
}
