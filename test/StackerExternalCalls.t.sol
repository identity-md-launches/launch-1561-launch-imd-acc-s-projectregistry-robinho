// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {TestIMD} from "./mocks/TestIMD.sol";
import {TestSIMD} from "./mocks/TestSIMD.sol";
import {Stacker, IStakedIMD} from "src/Stacker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Performs the real mock vault's transfer and mint before failing. This exercises rollback
/// after effects, unlike a paused vault which refuses a deposit before minting any shares.
contract LateFailureVault is TestSIMD {
    uint8 public failureMode;
    error RejectedAfterMint();

    constructor(address asset_, address owner_) TestSIMD(asset_, owner_) {}

    function setFailure(uint8 mode) external {
        failureMode = mode;
    }

    function deposit(uint256 assets, address to) public override returns (uint256 shares) {
        shares = super.deposit(assets, to);
        if (failureMode == 1) revert RejectedAfterMint();
        if (failureMode == 2) return 0;
    }
}

/// @dev A hook-capable token probes both of Stacker's token-call boundaries. The actual live
/// TestIMD has no hooks; this double checks the guard without assuming that dependency behavior.
contract HookedStackerIMD is TestIMD {
    Stacker public stacker;
    address public recipient;
    uint256 public attempts;
    bytes public lastError;

    function configure(Stacker target, address recipient_) external {
        stacker = target;
        recipient = recipient_;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (msg.sender == address(stacker)) _reenter();
        return super.approve(spender, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (msg.sender == address(stacker)) _reenter();
        return super.transferFrom(from, to, value);
    }

    function _reenter() internal {
        attempts++;
        (bool ok, bytes memory data) =
            address(stacker).call(abi.encodeCall(Stacker.credit, (recipient, 1)));
        require(!ok, "reentrant credit succeeded");
        lastError = data;
    }
}

contract NoReturnStackerIMD is TestIMD {
    function approve(address spender, uint256 value) public override returns (bool) {
        super.approve(spender, value);
        assembly ("memory-safe") { return(0, 0) }
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        super.transferFrom(from, to, value);
        assembly ("memory-safe") { return(0, 0) }
    }
}

/// forge-config: default.fuzz.runs = 1000
contract StackerExternalCallsTest is BaseTest {
    address internal project = makeAddr("external calls project");
    address internal trader = makeAddr("external calls trader");

    function setUp() public override {
        vm.chainId(11155111);
        super.setUp();
    }

    function testFuzz_lateFailureRollsBackAllEffects(
        uint96 rawAmount,
        bool zeroReturn,
        bool initialized
    ) public {
        _lateFailure(bound(rawAmount, 1, 50_000e18), zeroReturn, initialized);
    }

    function test_oneWeiLateRevertRollsBackFirstApproval() public {
        _lateFailure(1, false, false);
    }

    function test_zeroShareReturnRollsBackAnActualMint() public {
        _lateFailure(1e18, true, true);
    }

    function _lateFailure(uint256 amount, bool zeroReturn, bool initialized) internal {
        LateFailureVault vault = new LateFailureVault(address(imd), OWNER);
        sImd = TestSIMD(address(vault));
        stacker = new Stacker(IERC20(address(imd)), IStakedIMD(address(vault)));
        fund(project, amount + 10e18, amount + 10e18);
        if (initialized) {
            vm.prank(project);
            stacker.credit(trader, 10e18);
        }
        bytes32 before_ = _state();
        vault.setFailure(zeroReturn ? 2 : 1);
        vm.prank(project);
        vm.expectRevert(
            zeroReturn ? Stacker.ZeroShares.selector : LateFailureVault.RejectedAfterMint.selector
        );
        stacker.credit(trader, amount);
        assertEq(_state(), before_, "late error rolled back tokens, shares, approvals and counters");
        vault.setFailure(0);
        uint256 beforeShares = sImd.balanceOf(trader);
        vm.prank(project);
        uint256 minted = stacker.credit(trader, amount);
        assertGt(minted, 0);
        assertEq(sImd.balanceOf(trader), beforeShares + minted);
        assertEq(stacker.totalStacked(), amount + (initialized ? 10e18 : 0));
        assertEq(imd.balanceOf(address(stacker)), 0);
    }

    function _state() internal view returns (bytes32) {
        bytes32 tokenState = keccak256(
            abi.encode(
                imd.balanceOf(project),
                imd.balanceOf(address(stacker)),
                imd.balanceOf(address(sImd)),
                imd.allowance(project, address(stacker)),
                imd.allowance(address(stacker), address(sImd))
            )
        );
        return keccak256(
            abi.encode(
                tokenState,
                sImd.balanceOf(trader),
                sImd.totalSupply(),
                sImd.lastDepositBlock(trader),
                stacker.totalStacked(),
                stacker.projectStacked(project),
                stacker.projectShares(project)
            )
        );
    }

    function test_tokenReentryDuringApprovalAndPullCannotCreateExtraCashback() public {
        HookedStackerIMD token = new HookedStackerIMD();
        imd = token;
        sImd = new TestSIMD(address(token), OWNER);
        stacker = new Stacker(IERC20(address(token)), IStakedIMD(address(sImd)));
        token.configure(stacker, trader);
        fund(project, 3e18, 3e18);
        vm.prank(project);
        uint256 first = stacker.credit(trader, 1e18);
        assertEq(token.attempts(), 2, "approval and transferFrom both exercised");
        assertEq(
            token.lastError(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        vm.prank(project);
        uint256 second = stacker.credit(trader, 2e18);
        assertEq(token.attempts(), 3, "subsequent credit uses the existing vault approval");
        assertEq(
            token.lastError(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(stacker.totalStacked(), 3e18);
        assertEq(stacker.projectStacked(project), 3e18);
        assertEq(stacker.projectStacked(address(token)), 0, "hook caller never credited");
        assertEq(sImd.balanceOf(trader), first + second);
        assertEq(sImd.totalAssets(), 3e18);
        assertEq(imd.balanceOf(project), 0);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(sImd.balanceOf(address(stacker)), 0);
    }

    function test_noReturnTokenStillMovesExactAssetsAndShares() public {
        imd = new NoReturnStackerIMD();
        sImd = new TestSIMD(address(imd), OWNER);
        stacker = new Stacker(IERC20(address(imd)), IStakedIMD(address(sImd)));
        deal(address(imd), project, 42e18);
        vm.prank(project);
        (bool approved,) =
            address(imd).call(abi.encodeCall(IERC20.approve, (address(stacker), 42e18)));
        assertTrue(approved);
        vm.prank(project);
        uint256 shares = stacker.credit(trader, 42e18);
        assertEq(shares, 42e18 * SHARES_PER_IMD);
        assertEq(imd.balanceOf(project), 0);
        assertEq(imd.balanceOf(address(sImd)), 42e18);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(sImd.balanceOf(trader), shares);
        assertEq(stacker.projectShares(project), shares);
        assertEq(stacker.totalStacked(), 42e18);
    }

    function test_anotherCallersApprovalCannotBeSpent() public {
        fund(project, 10e18, 10e18);
        address stranger = makeAddr("stranger");
        bytes32 before_ = _state();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(stacker), 0, 10e18
            )
        );
        stacker.credit(trader, 10e18);
        assertEq(_state(), before_);
        assertEq(stacker.projectStacked(stranger), 0);
        assertEq(stacker.projectShares(stranger), 0);
    }

    /// @dev Compare two executions from the same vault state, using direct deposit as the
    /// independent oracle. This does not duplicate the vault's conversion formula or preview.
    function testFuzz_creditMatchesDirectDepositFromSameVaultState(
        uint96 rawSeed,
        uint96 rawDonation,
        uint96 rawAmount
    ) public {
        uint256 seed = bound(rawSeed, 1e18, 100_000e18);
        uint256 donation = bound(rawDonation, 0, 100_000e18);
        uint256 amount = bound(rawAmount, 1, 100_000e18);
        fund(project, seed + donation + amount, type(uint256).max);
        vm.startPrank(project);
        imd.approve(address(sImd), type(uint256).max);
        sImd.deposit(seed, project);
        imd.transfer(address(sImd), donation);
        vm.stopPrank();

        uint256 checkpoint = vm.snapshotState();
        vm.prank(project);
        uint256 directShares = sImd.deposit(amount, trader);
        uint256 directVaultAssets = sImd.totalAssets();
        uint256 directSupply = sImd.totalSupply();
        uint256 directProjectBalance = imd.balanceOf(project);
        uint256 directHold = sImd.lastDepositBlock(trader);
        assertTrue(vm.revertToStateAndDelete(checkpoint));
        vm.prank(project);
        uint256 creditedShares = stacker.credit(trader, amount);
        assertEq(creditedShares, directShares);
        assertEq(sImd.balanceOf(trader), directShares);
        assertEq(sImd.totalAssets(), directVaultAssets);
        assertEq(sImd.totalSupply(), directSupply);
        assertEq(imd.balanceOf(project), directProjectBalance);
        assertEq(sImd.lastDepositBlock(trader), directHold);
        assertEq(stacker.totalStacked(), amount);
        assertEq(stacker.projectStacked(project), amount);
        assertEq(stacker.projectShares(project), directShares);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(sImd.balanceOf(address(stacker)), 0);
    }
}
