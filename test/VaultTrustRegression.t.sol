// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";

/// @dev Reproduces retained properties of the live vault's local copy. This launch reuses it;
/// a minimum in Stacker would not stop deposits sent directly to the vault.
contract VaultTrustRegressionTest is BaseTest {
    function test_dustHoldThroughStackerAndDirectVault() public {
        address trader = makeAddr("trader");
        fund(address(this), 10e18 + 2, type(uint256).max);
        uint256 shares = stacker.credit(trader, 10e18);
        vm.roll(block.number + 100);
        assertEq(sImd.maxRedeem(trader), shares);
        assertEq(stacker.credit(trader, 1), 1e6);
        assertEq(sImd.maxRedeem(trader), 0);
        vm.prank(trader);
        vm.expectRevert(bytes4(keccak256("RedeemMoreThanMax()")));
        sImd.redeem(shares, trader, trader);
        vm.roll(block.number + 1);
        assertGt(sImd.maxRedeem(trader), 0);
        imd.approve(address(sImd), 1);
        sImd.deposit(1, trader);
        assertEq(sImd.maxRedeem(trader), 0, "direct deposits bypass any Stacker-only minimum");
        vm.roll(block.number + 1);
        vm.prank(trader);
        assertEq(sImd.redeem(shares, trader, trader), 10e18);
    }

    function test_vaultOwnerCanSweepCashback() public {
        address trader = makeAddr("trader");
        fund(address(this), 10e18, 10e18);
        uint256 shares = stacker.credit(trader, 10e18);
        assertEq(sImd.convertToAssets(shares), 10e18);
        uint256 balance = imd.balanceOf(address(sImd));
        vm.prank(OWNER);
        sImd.rescueERC20(address(imd), OWNER, balance);
        assertEq(imd.balanceOf(OWNER), 10e18);
        assertLt(sImd.convertToAssets(shares), 2);
    }
}
