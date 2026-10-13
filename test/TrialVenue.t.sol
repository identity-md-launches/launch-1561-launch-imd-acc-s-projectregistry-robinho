// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./Base.t.sol";
import {TrialVenue, IERC20Min, IStackerMin} from "./trial/TrialVenue.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";

/// @dev A router that reports its active caller, like Uniswap's Universal Router.
contract MsgSenderRouter {
    address public msgSender;

    function buy(TrialVenue venue, IERC20Min imd, uint256 amount) external {
        msgSender = msg.sender;
        require(imd.transferFrom(msg.sender, address(this), amount));
        imd.approve(address(venue), amount);
        uint256 out = venue.buy(amount, 0);
        venue.transfer(msg.sender, out);
        msgSender = address(0);
    }
}

/// @dev A contract caller that reports nobody.
contract PlainContract {
    function buy(TrialVenue venue, IERC20Min imd, uint256 amount) external {
        imd.approve(address(venue), amount);
        venue.buy(amount, 0);
    }
}

contract TrialVenueTest is BaseTest {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    TrialVenue internal venue;
    address internal trader = makeAddr("trader");

    function setUp() public override {
        super.setUp();
        vm.startPrank(OWNER);
        venue = new TrialVenue(
            IERC20Min(address(imd)), IStackerMin(address(stacker)), 1_300_000, 100_000
        );
        deal(address(imd), OWNER, 1_000e18);
        imd.approve(address(venue), 100e18);
        venue.seed(100e18);
        vm.stopPrank();
        deal(address(imd), trader, 100e18);
        vm.prank(trader);
        imd.approve(address(venue), type(uint256).max);
    }

    function test_buyCreditsHalfTheFeeAndBurnsTheOtherHalf() public {
        vm.recordLogs();
        vm.prank(trader);
        uint256 out = venue.buy(10e18, 0);
        (uint256 credited,) = stackedFromLogs(vm.getRecordedLogs(), address(venue), trader);
        assertEq(credited, 0.05e18, "0.5% cashback, credited as staked IMD");
        assertEq(imd.balanceOf(BURN), 0.05e18, "0.5% burned");
        assertGt(sImd.balanceOf(trader), 0);
        assertEq(venue.balanceOf(trader), out);
        assertEq(
            imd.balanceOf(address(venue)), venue.reserveImd(), "the venue keeps only its reserve"
        );
    }

    function test_sellCreditsHalfTheFeeAndBurnsTheOtherHalf() public {
        vm.prank(trader);
        uint256 got = venue.buy(10e18, 0);
        uint256 burnBefore = imd.balanceOf(BURN);
        uint256 before_ = imd.balanceOf(trader);
        vm.recordLogs();
        vm.prank(trader);
        uint256 imdOut = venue.sell(got, 0);
        (uint256 credited,) = stackedFromLogs(vm.getRecordedLogs(), address(venue), trader);
        uint256 gross = imdOut * 10_000 / 9_900;
        assertApproxEqAbs(credited, gross * 50 / 10_000, 2);
        uint256 burned = imd.balanceOf(BURN) - burnBefore;
        assertGe(burned, credited, "the burn is never below the cashback");
        assertLe(burned - credited, 1, "an odd wei goes to the burn");
        assertEq(imd.balanceOf(trader) - before_, imdOut);
        assertEq(imd.balanceOf(address(venue)), venue.reserveImd());
    }

    function test_routerCallerResolvesToItsActiveCaller() public {
        MsgSenderRouter router = new MsgSenderRouter();
        vm.prank(trader);
        imd.approve(address(router), type(uint256).max);
        vm.recordLogs();
        vm.prank(trader);
        router.buy(venue, IERC20Min(address(imd)), 10e18);
        (uint256 toTrader,) = stackedFromLogs(vm.getRecordedLogs(), address(venue), trader);
        assertEq(toTrader, 0.05e18, "the person behind the router gets the cashback");
        assertEq(sImd.balanceOf(address(router)), 0, "never the router");
    }

    function test_unknownContractCallerGetsNoCashbackItIsBurned() public {
        PlainContract c = new PlainContract();
        deal(address(imd), address(c), 10e18);
        vm.recordLogs();
        c.buy(venue, IERC20Min(address(imd)), 10e18);
        (uint256 credited,) = stackedFromLogs(vm.getRecordedLogs(), address(0), address(0));
        assertEq(credited, 0, "no credit");
        assertEq(imd.balanceOf(BURN), 0.1e18, "the whole fee is burned");
        assertEq(venue.resolveTrader(address(c)), address(0));
    }

    function test_pausedVaultPaysPlainImd() public {
        vm.prank(OWNER);
        sImd.setPaused(true);
        uint256 before_ = imd.balanceOf(trader);
        vm.prank(trader);
        venue.buy(10e18, 0);
        assertEq(
            before_ - imd.balanceOf(trader), 10e18 - 0.05e18, "cashback paid back as plain IMD"
        );
        assertEq(sImd.balanceOf(trader), 0);
    }

    function test_gasIsCheckedBeforeTheCredit() public {
        vm.prank(trader);
        vm.expectRevert(bytes("imd/acc: insufficient gas"));
        venue.buy{gas: 1_000_000}(10e18, 0);
    }

    function test_ownerCanOnlySeedOnce() public {
        vm.prank(OWNER);
        vm.expectRevert(TrialVenue.AlreadySeeded.selector);
        venue.seed(1e18);
        vm.prank(trader);
        vm.expectRevert(TrialVenue.NotOwner.selector);
        venue.seed(1e18);
    }

    function test_invalidTradersNeverResolve() public view {
        assertEq(venue.resolveTrader(address(stacker)), address(0));
        assertEq(venue.resolveTrader(address(imd)), address(0));
        assertEq(venue.resolveTrader(address(sImd)), address(0));
        assertEq(venue.resolveTrader(address(venue)), address(0));
        assertEq(venue.resolveTrader(trader), trader);
    }

    function test_registryReadsTheOwner() public {
        ProjectRegistry reg = new ProjectRegistry(
            address(0x1), address(imd), address(stacker), address(0x2), 1, 5e18, 3600
        );
        assertEq(reg.projectOwner(address(venue)), OWNER);
    }
}
