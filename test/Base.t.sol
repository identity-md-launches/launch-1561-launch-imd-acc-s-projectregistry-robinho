// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestIMD} from "./mocks/TestIMD.sol";
import {TestSIMD} from "./mocks/TestSIMD.sol";
import {Stacker, IStakedIMD} from "../src/Stacker.sol";

/// @dev Shared fixture: a test IMD, a copy of the StakedIMD vault (owner can pause it, so the failure
/// paths can be exercised) and the Stacker wired to both.
abstract contract BaseTest is Test {
    address internal constant OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;
    /// @dev Initial share price with the vault's decimals offset of 6: 1 IMD wei -> 1e6 shares.
    uint256 internal constant SHARES_PER_IMD = 1e6;
    bytes32 internal constant STACKED_TOPIC = keccak256("Stacked(address,address,uint256,uint256)");

    TestIMD internal imd;
    TestSIMD internal sImd;
    Stacker internal stacker;

    function setUp() public virtual {
        // Start from a non-trivial block/time so faucet and one-block-hold logic is not at zero.
        vm.roll(1_000);
        vm.warp(1_700_000_000);
        imd = new TestIMD();
        sImd = new TestSIMD(address(imd), OWNER);
        stacker = new Stacker(IERC20(address(imd)), IStakedIMD(address(sImd)));
    }

    /// @dev Gives `who` exactly `amount` tIMD (via storage) and approves the Stacker for `approval`.
    function fund(address who, uint256 amount, uint256 approval) internal {
        deal(address(imd), who, amount);
        vm.prank(who);
        imd.approve(address(stacker), approval);
    }

    /// @dev What an indexer does: add up the Stacker's `Stacked` events. `project` or `trader` set to
    /// address(0) matches any. Returns the IMD and the shares those events recorded.
    function stackedFromLogs(Vm.Log[] memory logs, address project, address trader)
        internal
        view
        returns (uint256 imdSum, uint256 sharesSum)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(stacker) || l.topics[0] != STACKED_TOPIC) continue;
            if (project != address(0) && address(uint160(uint256(l.topics[1]))) != project) {
                continue;
            }
            if (trader != address(0) && address(uint160(uint256(l.topics[2]))) != trader) continue;
            (uint256 a, uint256 s) = abi.decode(l.data, (uint256, uint256));
            imdSum += a;
            sharesSum += s;
        }
    }
}
