// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";
import {BaseTest} from "./Base.t.sol";
import {TestIMD} from "./mocks/TestIMD.sol";
import {Stacker, IStakedIMD} from "../src/Stacker.sol";

/// @dev A project hook the way integrators are expected to write it: cashback must never break the
/// project's own flow, so `credit` is wrapped in try/catch.
contract MockProjectHook {
    Stacker public immutable stacker;
    uint256 public failures;

    constructor(Stacker stacker_, IERC20 imd) {
        stacker = stacker_;
        imd.approve(address(stacker_), type(uint256).max);
    }

    function pay(address trader, uint256 amount) external returns (bool ok, uint256 shares) {
        try stacker.credit(trader, amount) returns (uint256 s) {
            return (true, s);
        } catch {
            failures++;
            return (false, 0);
        }
    }
}

contract StackerTest is BaseTest {
    address internal project = makeAddr("project");
    address internal trader = makeAddr("trader");

    function setUp() public override {
        super.setUp();
        fund(project, 1_000_000e18, type(uint256).max);
    }

    // ───────────────────────────── constructor ─────────────────────────────

    function test_constructor_wiringWithoutExternalCalls() public view {
        assertEq(address(stacker.IMD()), address(imd));
        assertEq(address(stacker.SIMD()), address(sImd));
        assertEq(imd.allowance(address(stacker), address(sImd)), 0);
        assertEq(stacker.totalStacked(), 0);
    }

    function test_firstCredit_revertsOnAssetMismatch() public {
        TestIMD other = new TestIMD();
        Stacker wrong = new Stacker(IERC20(address(other)), IStakedIMD(address(sImd)));
        vm.expectRevert(
            abi.encodeWithSelector(Stacker.AssetMismatch.selector, address(imd), address(other))
        );
        wrong.credit(trader, 1e18);
        assertEq(other.allowance(address(wrong), address(sImd)), 0);
        assertEq(wrong.totalStacked(), 0);
    }

    function test_constructor_vaultWithoutCode_creditCannotMove() public {
        // The launch rehearsal deploys on an empty chain: the vault address has no code there.
        address noVault = makeAddr("noVault");
        Stacker rehearsal = new Stacker(IERC20(address(imd)), IStakedIMD(noVault));
        assertEq(address(rehearsal.SIMD()), noVault);
        assertEq(imd.allowance(address(rehearsal), noVault), 0, "no approval without a vault");

        // The missing vault makes first-use validation revert before any tokens are pulled.
        vm.prank(project);
        imd.approve(address(rehearsal), type(uint256).max);
        vm.prank(project);
        vm.expectRevert();
        rehearsal.credit(trader, 1e18);
        assertEq(imd.balanceOf(project), 1_000_000e18, "nothing moved");
        assertEq(imd.balanceOf(address(rehearsal)), 0);
    }

    function test_constructor_doesNotCallExistingVaultOrToken() public {
        vm.mockCallRevert(
            address(sImd), abi.encodeWithSelector(IStakedIMD.asset.selector), "unavailable"
        );
        vm.mockCallRevert(
            address(imd), abi.encodeWithSelector(IERC20.approve.selector), "unavailable"
        );
        Stacker cold = new Stacker(IERC20(address(imd)), IStakedIMD(address(sImd)));
        assertEq(address(cold.SIMD()), address(sImd));
        assertEq(cold.credit(trader, 0), 0, "zero credit does not initialize the vault");
        assertEq(imd.allowance(address(cold), address(sImd)), 0);
    }

    function test_firstCredit_approvesOnce_andLaterCreditsStillWork() public {
        vm.prank(project);
        stacker.credit(trader, 1e18);
        assertEq(imd.allowance(address(stacker), address(sImd)), type(uint256).max);
        vm.mockCallRevert(
            address(sImd), abi.encodeWithSelector(IStakedIMD.asset.selector), "checked once"
        );
        vm.mockCallRevert(
            address(imd), abi.encodeWithSelector(IERC20.approve.selector), "approved once"
        );
        vm.prank(project);
        stacker.credit(trader, 2e18);
        assertEq(stacker.totalStacked(), 3e18);
    }

    function test_failedFirstCredit_rollsBackApprovalAndRetriesValidation() public {
        vm.prank(OWNER);
        sImd.setPaused(true);
        vm.prank(project);
        vm.expectRevert();
        stacker.credit(trader, 1e18);
        assertEq(imd.allowance(address(stacker), address(sImd)), 0);
        vm.prank(OWNER);
        sImd.setPaused(false);
        vm.mockCall(
            address(sImd), abi.encodeWithSelector(IStakedIMD.asset.selector), abi.encode(trader)
        );
        vm.prank(project);
        vm.expectRevert(
            abi.encodeWithSelector(Stacker.AssetMismatch.selector, trader, address(imd))
        );
        stacker.credit(trader, 1e18);
        vm.clearMockedCalls();
        vm.prank(project);
        assertGt(stacker.credit(trader, 1e18), 0);
    }

    // ───────────────────────────── credit: success ─────────────────────────────

    function test_credit_sharesGoOnlyToTrader() public {
        uint256 amount = 100e18;
        uint256 expectedShares = sImd.previewDeposit(amount);
        assertEq(expectedShares, amount * SHARES_PER_IMD);

        vm.prank(project);
        uint256 shares = stacker.credit(trader, amount);

        assertEq(shares, expectedShares);
        assertEq(sImd.balanceOf(trader), shares, "trader got every share");
        assertEq(sImd.balanceOf(project), 0, "project got no shares");
        assertEq(sImd.balanceOf(address(stacker)), 0, "stacker keeps no shares");
        assertEq(imd.balanceOf(address(stacker)), 0, "stacker keeps no IMD");
        assertEq(imd.balanceOf(project), 1_000_000e18 - amount, "IMD pulled from project");
        assertEq(imd.balanceOf(address(sImd)), amount, "IMD sits in the vault");
        assertEq(sImd.lastDepositBlock(trader), block.number, "vault hold stamped on trader");
    }

    function test_credit_totalsAndEvent() public {
        uint256 amount = 42e18;
        uint256 expectedShares = sImd.previewDeposit(amount);

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(stacker));
        emit Stacker.Stacked(project, trader, amount, expectedShares);
        vm.prank(project);
        stacker.credit(trader, amount);

        assertEq(stacker.projectStacked(project), amount);
        assertEq(stacker.totalStacked(), amount);
        assertEq(stacker.projectShares(project), expectedShares);

        // A second credit accumulates rather than overwrites.
        vm.prank(project);
        uint256 shares2 = stacker.credit(trader, amount);
        assertEq(stacker.projectStacked(project), 2 * amount);
        assertEq(stacker.totalStacked(), 2 * amount);
        assertEq(stacker.projectShares(project), expectedShares + shares2);
        assertEq(sImd.balanceOf(trader), expectedShares + shares2);

        // The trader's own figures come from the events, as the dashboard computes them.
        (uint256 tImd, uint256 tShares) = stackedFromLogs(vm.getRecordedLogs(), project, trader);
        assertEq(tImd, 2 * amount, "trader IMD from events");
        assertEq(tShares, expectedShares + shares2, "trader shares from events");
    }

    function test_credit_manyProjectsAndTraders() public {
        uint256 nProjects = 5;
        uint256 nTraders = 7;
        address[] memory projects = new address[](nProjects);
        address[] memory traders = new address[](nTraders);
        for (uint256 p; p < nProjects; ++p) {
            projects[p] = makeAddr(string.concat("project", vm.toString(p)));
            fund(projects[p], 1_000_000e18, type(uint256).max);
        }
        for (uint256 t; t < nTraders; ++t) {
            traders[t] = makeAddr(string.concat("trader", vm.toString(t)));
        }

        uint256 total;
        uint256 totalShares;
        vm.recordLogs();
        for (uint256 p; p < nProjects; ++p) {
            for (uint256 t; t < nTraders; ++t) {
                uint256 amount = (p + 1) * (t + 1) * 1e18;
                vm.expectEmit(true, true, false, false, address(stacker));
                emit Stacker.Stacked(projects[p], traders[t], 0, 0);
                vm.prank(projects[p]);
                uint256 shares = stacker.credit(traders[t], amount);
                assertGt(shares, 0);
                total += amount;
                totalShares += shares;
            }
        }
        assertEq(stacker.totalStacked(), total);
        assertEq(imd.balanceOf(address(sImd)), total);
        assertEq(sImd.totalSupply(), totalShares);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 sumTraders;
        uint256 sumTraderShares;
        for (uint256 t; t < nTraders; ++t) {
            (uint256 tImd, uint256 tShares) = stackedFromLogs(logs, address(0), traders[t]);
            sumTraders += tImd;
            sumTraderShares += tShares;
            assertEq(sImd.balanceOf(traders[t]), tShares, "events match the trader's shares");
            uint256 expectedTrader;
            for (uint256 p; p < nProjects; ++p) {
                uint256 amount = (p + 1) * (t + 1) * 1e18;
                (uint256 byImd,) = stackedFromLogs(logs, projects[p], traders[t]);
                assertEq(byImd, amount, "per project and trader from events");
                expectedTrader += amount;
            }
            assertEq(tImd, expectedTrader);
        }
        uint256 sumProjects;
        uint256 sumProjectShares;
        for (uint256 p; p < nProjects; ++p) {
            sumProjects += stacker.projectStacked(projects[p]);
            sumProjectShares += stacker.projectShares(projects[p]);
            assertEq(sImd.balanceOf(projects[p]), 0, "projects never hold shares");
            assertEq(imd.balanceOf(projects[p]), 1_000_000e18 - stacker.projectStacked(projects[p]));
        }
        assertEq(sumTraders, total);
        assertEq(sumProjects, total);
        assertEq(sumTraderShares, totalShares);
        assertEq(sumProjectShares, totalShares);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(sImd.balanceOf(address(stacker)), 0);
    }

    function test_credit_sharesFollowVaultPrice() public {
        // First deposit at 1 IMD wei = 1e6 shares. A donation raises the price; later credits get
        // fewer shares per IMD, exactly what the vault previews.
        vm.prank(project);
        uint256 shares1 = stacker.credit(trader, 100e18);
        deal(address(imd), address(sImd), imd.balanceOf(address(sImd)) + 100e18);
        uint256 preview = sImd.previewDeposit(100e18);
        vm.prank(project);
        uint256 shares2 = stacker.credit(trader, 100e18);
        assertEq(shares2, preview);
        assertLt(shares2, shares1);
        assertEq(sImd.balanceOf(trader), shares1 + shares2);
    }

    // ───────────────────────────── credit: zero paths ─────────────────────────────

    function test_credit_zeroTraderReverts() public {
        vm.prank(project);
        vm.expectRevert(Stacker.ZeroTrader.selector);
        stacker.credit(address(0), 1e18);
        // Zero trader beats zero amount: it reverts even for amount 0.
        vm.prank(project);
        vm.expectRevert(Stacker.ZeroTrader.selector);
        stacker.credit(address(0), 0);
    }

    function test_credit_zeroAmountReturnsZeroNoEvent() public {
        vm.recordLogs();
        vm.prank(project);
        uint256 shares = stacker.credit(trader, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(shares, 0);
        assertEq(logs.length, 0, "no event, no transfer");
        assertEq(stacker.projectStacked(project), 0);
        assertEq(stacker.totalStacked(), 0);
        assertEq(sImd.balanceOf(trader), 0);
        assertEq(imd.balanceOf(project), 1_000_000e18);
    }

    // ───────────────────────────── credit: failures ─────────────────────────────

    function test_credit_revertsWhenVaultPaused() public {
        vm.prank(OWNER);
        sImd.setPaused(true);

        vm.prank(project);
        vm.expectRevert(ERC4626.DepositMoreThanMax.selector);
        stacker.credit(trader, 1e18);
        assertEq(imd.balanceOf(project), 1_000_000e18, "nothing pulled");
        assertEq(stacker.totalStacked(), 0);

        vm.prank(OWNER);
        sImd.setPaused(false);
        vm.prank(project);
        stacker.credit(trader, 1e18);
        assertEq(stacker.totalStacked(), 1e18);
    }

    function test_credit_revertsOnShortAllowance() public {
        address tight = makeAddr("tight");
        fund(tight, 10e18, 5e18);
        vm.prank(tight);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(stacker), 5e18, 6e18
            )
        );
        stacker.credit(trader, 6e18);
        assertEq(imd.balanceOf(tight), 10e18);
        assertEq(stacker.totalStacked(), 0);
    }

    function test_credit_revertsOnShortBalance() public {
        address poor = makeAddr("poor");
        fund(poor, 3e18, type(uint256).max);
        vm.prank(poor);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 3e18, 4e18)
        );
        stacker.credit(trader, 4e18);
        assertEq(stacker.totalStacked(), 0);
    }

    function test_credit_revertsOnZeroShares() public {
        // A donation of >= 1e6 wei with no shares outstanding makes a 1 wei deposit preview to 0
        // shares; the Stacker refuses rather than losing the trader's IMD to the vault.
        deal(address(imd), address(sImd), 1e6);
        assertEq(sImd.previewDeposit(1), 0);
        vm.prank(project);
        vm.expectRevert(Stacker.ZeroShares.selector);
        stacker.credit(trader, 1);
        assertEq(imd.balanceOf(project), 1_000_000e18);
    }

    function test_integrator_tryCatchSurvivesPausedVault() public {
        MockProjectHook hook = new MockProjectHook(stacker, IERC20(address(imd)));
        deal(address(imd), address(hook), 100e18);

        (bool ok, uint256 shares) = hook.pay(trader, 10e18);
        assertTrue(ok);
        assertEq(shares, sImd.balanceOf(trader));
        assertEq(hook.failures(), 0);

        vm.prank(OWNER);
        sImd.setPaused(true);
        (ok, shares) = hook.pay(trader, 10e18);
        assertFalse(ok, "paused vault: credit failed but the hook's own call succeeded");
        assertEq(shares, 0);
        assertEq(hook.failures(), 1);
        assertEq(imd.balanceOf(address(hook)), 90e18, "failed credit moved nothing");
        assertEq(stacker.projectStacked(address(hook)), 10e18);

        // Allowance short: the hook revokes its approval and credit fails the same way.
        vm.prank(OWNER);
        sImd.setPaused(false);
        vm.prank(address(hook));
        imd.approve(address(stacker), 0);
        (ok,) = hook.pay(trader, 10e18);
        assertFalse(ok);
        assertEq(hook.failures(), 2);
    }

    // ───────────────────────────── fuzz ─────────────────────────────

    function testFuzz_credit(address who, uint256 amount) public {
        // Invalid recipients have dedicated rejection coverage in StackerAuditRegression.t.sol.
        vm.assume(
            who != address(0) && who != address(stacker) && who != address(sImd)
                && who != address(imd)
        );
        amount = bound(amount, 1, 1_000_000e18);
        uint256 preview = sImd.previewDeposit(amount);

        vm.recordLogs();
        vm.prank(project);
        uint256 shares = stacker.credit(who, amount);
        (uint256 evImd, uint256 evShares) = stackedFromLogs(vm.getRecordedLogs(), project, who);

        assertEq(shares, preview);
        assertEq(sImd.balanceOf(who), shares);
        assertEq(evImd, amount, "event IMD");
        assertEq(evShares, shares, "event shares");
        assertEq(stacker.projectStacked(project), amount);
        assertEq(stacker.totalStacked(), amount);
        assertEq(stacker.projectShares(project), shares);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(sImd.balanceOf(address(stacker)), 0);
        assertEq(imd.balanceOf(address(sImd)), amount);
    }

    function testFuzz_credit_twoTradersProportional(uint256 a, uint256 b) public {
        a = bound(a, 1, 500_000e18);
        b = bound(b, 1, 500_000e18);
        address t2 = makeAddr("t2");
        vm.prank(project);
        uint256 sa = stacker.credit(trader, a);
        vm.prank(project);
        uint256 sb = stacker.credit(t2, b);
        assertEq(sa, a * SHARES_PER_IMD);
        // The second deposit sees totalAssets = a and totalSupply = a*1e6: price still ~1e6 per wei.
        assertEq(sb, (b * (a * SHARES_PER_IMD + SHARES_PER_IMD)) / (a + 1));
        assertEq(stacker.totalStacked(), a + b);
        assertEq(sImd.totalSupply(), sa + sb);
    }

    function testFuzz_credit_shortAllowanceAlwaysReverts(uint256 allowance, uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        allowance = bound(allowance, 0, amount - 1);
        address p = makeAddr("fuzzProject");
        fund(p, amount, allowance);
        vm.prank(p);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(stacker),
                allowance,
                amount
            )
        );
        stacker.credit(trader, amount);
    }
}
