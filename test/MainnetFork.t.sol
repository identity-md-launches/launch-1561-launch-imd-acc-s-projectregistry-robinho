// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Stacker, IStakedIMD} from "../src/Stacker.sol";

/// @dev The parts of the live StakedIMD vault these tests read.
interface ILiveVault {
    function asset() external view returns (address);
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
    function previewDeposit(uint256) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function redeem(uint256 shares, address to, address owner) external returns (uint256);
}

/// @dev Runs against a fork of Ethereum mainnet with the live IMD and sIMD. Set ETH_RPC_URL to run
/// it (for example `ETH_RPC_URL=https://ethereum-rpc.publicnode.com forge test --mc MainnetFork`);
/// without it every test is skipped, so the suite also runs offline.
contract MainnetForkTest is Test {
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SIMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;

    ILiveVault internal vault = ILiveVault(SIMD);
    Stacker internal stacker;
    address internal project = makeAddr("project");
    address internal trader = makeAddr("trader");
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        if (block.chainid != 1) return; // another network's RPC: skip rather than fail
        forked = true;
        stacker = new Stacker(IERC20(IMD), IStakedIMD(SIMD));
        deal(IMD, project, 1_000e18);
        vm.prank(project);
        IERC20(IMD).approve(address(stacker), type(uint256).max);
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function test_fork_liveFacts() public onlyFork {
        assertEq(vault.asset(), IMD, "vault asset is IMD");
        assertEq(vault.owner(), address(0), "vault owner renounced");
        assertFalse(vault.paused(), "vault open");
        assertEq(vault.decimals(), 24);
        assertEq(
            IERC20(IMD).allowance(address(stacker), SIMD), 0, "approval deferred to first credit"
        );
    }

    function test_fork_creditNewThenRepeatTrader() public onlyFork {
        uint256 preview = vault.previewDeposit(1e18);
        vm.recordLogs();
        vm.prank(project);
        uint256 shares = stacker.credit(trader, 1e18);
        assertEq(shares, preview, "shares match the live vault's preview");
        assertEq(vault.balanceOf(trader), shares, "shares went to the trader");
        uint256 value = vault.convertToAssets(shares);
        assertLe(value, 1e18, "no free profit");
        assertGe(value + 1e12, 1e18, "value within rounding of the cashback");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.emitter, address(stacker));
        (uint256 evImd, uint256 evShares) = abi.decode(last.data, (uint256, uint256));
        assertEq(evImd, 1e18);
        assertEq(evShares, shares);

        vm.prank(project);
        uint256 shares2 = stacker.credit(trader, 0.5e18);
        assertEq(vault.balanceOf(trader), shares + shares2);
        assertEq(stacker.projectStacked(project), 1.5e18);
        assertEq(stacker.totalStacked(), 1.5e18);
        assertEq(IERC20(IMD).balanceOf(address(stacker)), 0, "Stacker holds no IMD");
        assertEq(vault.balanceOf(address(stacker)), 0, "Stacker holds no sIMD");
    }

    function test_fork_oneBlockHoldThenRedeem() public onlyFork {
        vm.prank(project);
        uint256 shares = stacker.credit(trader, 2e18);
        vm.prank(trader);
        vm.expectRevert();
        vault.redeem(shares, trader, trader);

        vm.roll(block.number + 1);
        vm.prank(trader);
        uint256 got = vault.redeem(shares, trader, trader);
        assertLe(got, 2e18);
        assertGe(got + 1e12, 2e18);
        assertEq(IERC20(IMD).balanceOf(trader), got);
    }

    function test_fork_firstCreditNeedsInitializationGas() public onlyFork {
        // The original README's 136k x 1.3 budget fails until a credit succeeds in full.
        for (uint256 i; i < 2; ++i) {
            vm.prank(project);
            (bool ok, bytes memory data) =
                address(stacker).call{gas: 177_000}(abi.encodeCall(Stacker.credit, (trader, 1e18)));
            assertFalse(ok);
            assertEq(data.length, 0, "out of gas");
            assertEq(IERC20(IMD).balanceOf(project), 1_000e18);
            assertEq(IERC20(IMD).allowance(address(stacker), SIMD), 0);
            assertEq(stacker.totalStacked(), 0);
        }

        vm.prank(project);
        uint256 shares = stacker.credit{gas: 350_000}(trader, 1e18);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(trader), shares);
        assertEq(IERC20(IMD).allowance(address(stacker), SIMD), type(uint256).max);
        assertEq(stacker.totalStacked(), 1e18);

        address newTrader = makeAddr("gas fork new trader");
        vm.prank(project);
        shares = stacker.credit{gas: 177_000}(newTrader, 1e18);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(newTrader), shares);
        assertEq(stacker.totalStacked(), 2e18);
    }

    function test_fork_readmeBudgetFundsColdFirstCredit() public onlyFork {
        // No prior credit or balance/allowance reads in this transaction: exercise cold state.
        vm.prank(project);
        uint256 shares = stacker.credit{gas: 350_000}(trader, 1e18);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(trader), shares);
        assertEq(stacker.projectStacked(project), 1e18);
        assertEq(IERC20(IMD).balanceOf(address(stacker)), 0);
        assertEq(vault.balanceOf(address(stacker)), 0);
    }
}
