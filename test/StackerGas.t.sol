// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTest} from "./Base.t.sol";
import {Stacker, IStakedIMD} from "../src/Stacker.sol";
import {LateFailureVault} from "./StackerExternalCalls.t.sol";

/// @dev Test-only integration of the README's gas guard, bounded call and plain-IMD fallback.
contract GasBudgetProject {
    Stacker internal immutable stacker;
    IERC20 internal immutable imd;

    constructor(Stacker stacker_, IERC20 imd_) {
        stacker = stacker_;
        imd = imd_;
        imd_.approve(address(stacker_), type(uint256).max);
    }

    function pay(address trader, uint256 cashback) external returns (uint256 shares) {
        require(gasleft() >= 410_000, "imd/acc: insufficient gas");
        try stacker.credit{gas: 350_000}(trader, cashback) returns (uint256 minted) {
            return minted;
        } catch {
            require(imd.transfer(trader, cashback), "IMD transfer failed");
            return 0;
        }
    }
}

contract StackerGasTest is BaseTest {
    GasBudgetProject internal hook;
    address internal project = makeAddr("gas project");
    address internal trader = makeAddr("gas trader");

    function setUp() public override {
        super.setUp();
        hook = new GasBudgetProject(stacker, IERC20(address(imd)));
        deal(address(imd), address(hook), 10e18);
        fund(project, 10e18, type(uint256).max);
    }

    function test_oldGasCapFailsRepeatedlyAndDoesNotPrimeVault() public {
        for (uint256 i; i < 2; ++i) {
            vm.prank(project);
            (bool ok, bytes memory data) =
                address(stacker).call{gas: 177_000}(abi.encodeCall(Stacker.credit, (trader, 1e18)));
            assertFalse(ok, "136k x 1.3 cannot fund first-use setup");
            assertEq(data.length, 0, "out of gas, not a token/vault error");
            assertEq(imd.allowance(address(stacker), address(sImd)), 0);
            assertEq(imd.balanceOf(project), 10e18);
            assertEq(imd.balanceOf(address(stacker)), 0);
            assertEq(sImd.totalSupply(), 0);
            assertEq(stacker.projectStacked(project), 0);
            assertEq(stacker.projectShares(project), 0);
            assertEq(stacker.totalStacked(), 0);
        }

        vm.prank(project);
        stacker.credit(trader, 1e18);
        address secondTrader = makeAddr("second gas trader");
        vm.prank(project);
        (bool later,) = address(stacker).call{gas: 177_000}(
            abi.encodeCall(Stacker.credit, (secondTrader, 1e18))
        );
        assertTrue(later, "the same cap works after first-use setup");
        assertEq(stacker.totalStacked(), 2e18);
    }

    function test_readmeBudgetFundsColdFirstCredit() public {
        // Only 1k above the documented check, to cover entry/ABI decoding before gasleft().
        uint256 shares = hook.pay{gas: 411_000}(trader, 1e18);
        assertGt(shares, 0, "cashback did not silently take the fallback");
        assertEq(sImd.balanceOf(trader), shares);
        assertEq(imd.balanceOf(trader), 0);
        assertEq(imd.balanceOf(address(hook)), 9e18);
        assertEq(stacker.projectStacked(address(hook)), 1e18);
        assertEq(imd.allowance(address(stacker), address(sImd)), type(uint256).max);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(sImd.balanceOf(address(stacker)), 0);
    }

    function test_readmeGasGuardRejectsLowEstimateBeforeFallback() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "imd/acc: insufficient gas"));
        hook.pay{gas: 400_000}(trader, 1e18);
        assertEq(imd.balanceOf(address(hook)), 10e18);
        assertEq(imd.balanceOf(trader), 0);
        assertEq(sImd.balanceOf(trader), 0);
        assertEq(stacker.totalStacked(), 0);
        assertEq(imd.allowance(address(stacker), address(sImd)), 0);
    }

    function test_readmeFallbackPaysPlainImdWhenVaultFails() public {
        vm.prank(OWNER);
        sImd.setPaused(true);
        assertEq(hook.pay{gas: 411_000}(trader, 1e18), 0);
        assertEq(imd.balanceOf(trader), 1e18);
        assertEq(imd.balanceOf(address(hook)), 9e18);
        assertEq(sImd.balanceOf(trader), 0);
        assertEq(stacker.totalStacked(), 0);
        assertEq(imd.allowance(address(stacker), address(sImd)), 0);
    }

    function test_readmeFallbackHasGasEvenWhenCreditExhaustsItsBudget() public {
        // Simulate an external vault consuming all the forwarded gas during first-use validation.
        // INVALID exceptionally halts its call and burns that call's remaining gas.
        vm.etch(address(sImd), hex"fe");
        assertEq(hook.pay{gas: 411_000}(trader, 1e18), 0);
        assertEq(imd.balanceOf(trader), 1e18);
        assertEq(imd.balanceOf(address(hook)), 9e18);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(stacker.totalStacked(), 0);
        assertEq(imd.allowance(address(stacker), address(sImd)), 0);
    }

    function test_readmeFallbackAfterFirstMintReturnsZeroShares() public {
        _fallbackAfterMint(1, false, true);
    }

    function test_readmeFallbackAfterRepeatMintReverts() public {
        _fallbackAfterMint(10e18, true, false);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_readmeLateFailurePaysOnceAndNextCreditWorks(
        uint96 amount,
        bool initialized,
        bool zeroReturn
    ) public {
        _fallbackAfterMint(bound(amount, 1, 50_000e18), initialized, zeroReturn);
    }

    /// @dev Exercise the existing README integration with failure AFTER both transfers and
    /// a real share mint. The catch must pay from the restored project balance exactly once.
    function _fallbackAfterMint(uint256 amount, bool initialized, bool zeroReturn) internal {
        LateFailureVault vault = new LateFailureVault(address(imd), OWNER);
        sImd = vault;
        stacker = new Stacker(IERC20(address(imd)), IStakedIMD(address(vault)));
        hook = new GasBudgetProject(stacker, IERC20(address(imd)));
        uint256 seed = initialized ? 1e18 : 0;
        deal(address(imd), address(hook), seed + 2 * amount);
        if (initialized) {
            assertEq(hook.pay{gas: 411_000}(trader, seed), seed * SHARES_PER_IMD);
        }
        uint256 oldHold = vault.lastDepositBlock(trader);
        vm.roll(block.number + 1);

        vault.setFailure(zeroReturn ? 2 : 1);
        vm.expectCall(address(vault), abi.encodeCall(IStakedIMD.deposit, (amount, trader)));
        assertEq(hook.pay{gas: 411_000}(trader, amount), 0, "fallback returns no shares");
        assertEq(imd.balanceOf(trader), amount, "plain IMD paid exactly once");
        assertEq(imd.balanceOf(address(hook)), amount, "failed credit did not also charge project");
        assertEq(vault.totalAssets(), seed, "failed deposit left no assets in vault");
        assertEq(vault.totalSupply(), seed * SHARES_PER_IMD, "failed mint unwound");
        assertEq(vault.balanceOf(trader), seed * SHARES_PER_IMD);
        assertEq(vault.lastDepositBlock(trader), oldHold, "failed mint did not renew hold");
        assertEq(vault.maxRedeem(trader), seed * SHARES_PER_IMD);
        assertEq(stacker.totalStacked(), seed, "plain IMD is not counted as staked cashback");
        assertEq(stacker.projectStacked(address(hook)), seed);
        assertEq(stacker.projectShares(address(hook)), seed * SHARES_PER_IMD);
        assertEq(imd.allowance(address(hook), address(stacker)), type(uint256).max);
        assertEq(
            imd.allowance(address(stacker), address(vault)),
            initialized ? type(uint256).max : 0,
            "only a successful first credit can retain initialization"
        );
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(vault.balanceOf(address(stacker)), 0);

        vault.setFailure(0);
        uint256 minted = hook.pay{gas: 411_000}(trader, amount);
        assertEq(minted, amount * SHARES_PER_IMD, "retry must take the staking path");
        assertEq(imd.balanceOf(trader), amount, "successful retry must not pay fallback too");
        assertEq(imd.balanceOf(address(hook)), 0, "retry spends the remaining project balance");
        assertEq(vault.totalAssets(), seed + amount);
        assertEq(vault.totalSupply(), (seed + amount) * SHARES_PER_IMD);
        assertEq(vault.balanceOf(trader), (seed + amount) * SHARES_PER_IMD);
        assertEq(vault.lastDepositBlock(trader), block.number);
        assertEq(stacker.totalStacked(), seed + amount);
        assertEq(stacker.projectStacked(address(hook)), seed + amount);
        assertEq(stacker.projectShares(address(hook)), (seed + amount) * SHARES_PER_IMD);
        assertEq(imd.allowance(address(stacker), address(vault)), type(uint256).max);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(vault.balanceOf(address(stacker)), 0);
    }
}
