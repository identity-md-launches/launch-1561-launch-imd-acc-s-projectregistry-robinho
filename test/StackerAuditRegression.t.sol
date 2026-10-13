// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {Stacker} from "../src/Stacker.sol";

contract StackerAuditRegressionTest is BaseTest {
    address internal project = makeAddr("audit project");
    address internal trader = makeAddr("audit trader");

    function setUp() public override {
        super.setUp();
        fund(project, 10e18, 10e18);
    }

    function test_creditToStackerRevertsWithoutEffects() public {
        _reject(address(stacker), 1e18);
    }

    function test_creditToVaultRevertsWithoutEffects() public {
        _reject(address(sImd), 1e18);
    }

    function test_creditToImdTokenRevertsWithoutEffects() public {
        _reject(address(imd), 1e18);
    }

    function test_zeroAmountStillRejectsUnreachableRecipients() public {
        _reject(address(stacker), 0);
        _reject(address(sImd), 0);
        _reject(address(imd), 0);
    }

    function testFuzz_unreachableRecipientsRejectedBeforeAndAfterFirstCredit(
        uint256 amount,
        bool initialized
    ) public {
        if (initialized) {
            vm.prank(project);
            stacker.credit(trader, 1e18);
        }
        // Even zero or an unfundable amount must fail recipient validation first.
        _reject(address(stacker), amount);
        _reject(address(sImd), amount);
        _reject(address(imd), amount);

        // Rejections must not poison the guard or prevent a valid subsequent credit.
        vm.prank(project);
        uint256 shares = stacker.credit(trader, 1e18);
        assertGt(shares, 0);
        assertEq(stacker.totalStacked(), initialized ? 2e18 : 1e18);
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(sImd.balanceOf(address(stacker)), 0);
    }

    function _reject(address recipient, uint256 amount) internal {
        bytes32 before_ = _state();
        vm.recordLogs();
        vm.prank(project);
        vm.expectRevert(Stacker.InvalidTrader.selector);
        stacker.credit(recipient, amount);
        assertEq(vm.getRecordedLogs().length, 0, "no transfers, approvals or Stacked event");
        assertEq(_state(), before_, "no tokens, shares, approvals, hold stamps or totals changed");
    }

    function _state() internal view returns (bytes32) {
        bytes32 tokens = keccak256(
            abi.encode(
                imd.balanceOf(project),
                imd.balanceOf(address(stacker)),
                imd.balanceOf(address(sImd)),
                imd.allowance(project, address(stacker)),
                imd.allowance(address(stacker), address(sImd))
            )
        );
        bytes32 shares = keccak256(
            abi.encode(
                sImd.totalSupply(),
                sImd.balanceOf(address(stacker)),
                sImd.balanceOf(address(sImd)),
                sImd.balanceOf(address(imd)),
                sImd.balanceOf(trader),
                sImd.lastDepositBlock(address(stacker)),
                sImd.lastDepositBlock(address(sImd)),
                sImd.lastDepositBlock(address(imd)),
                sImd.lastDepositBlock(trader)
            )
        );
        return keccak256(
            abi.encode(
                tokens,
                shares,
                stacker.totalStacked(),
                stacker.projectStacked(project),
                stacker.projectShares(project)
            )
        );
    }
}
