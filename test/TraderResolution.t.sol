// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Stacker} from "../src/Stacker.sol";
import {BaseTest} from "./Base.t.sol";

/// @dev Minimal callback model: PoolManager passes its swap caller as the hook's sender.
contract ResolutionPool {
    function swap(ResolutionHook hook, bytes calldata hookData, bool legacy) external {
        hook.afterSwap(msg.sender, hookData, legacy);
    }
}

/// @dev Models the active msgSender context and permissionless token sweep of Universal Router.
/// No Uniswap dependency or deployed router is required for these offline regressions.
contract ResolutionRouter {
    address public msgSender;

    function swap(ResolutionPool pool, ResolutionHook hook, bytes calldata hookData, bool legacy)
        external
    {
        msgSender = msg.sender;
        pool.swap(hook, hookData, legacy);
        msgSender = address(0);
    }

    function sweep(IERC20 token, address to) external {
        require(token.transfer(to, token.balanceOf(address(this))));
    }
}

/// @dev Test-only integration of README rule 3, with 20-byte packed hookData as this router's
/// agreed encoding. Real integrations must decode their own router's format and authenticate
/// PoolManager callbacks. The legacy branch is retained solely to reproduce the reported loss.
contract ResolutionHook {
    ResolutionPool internal immutable pool;
    Stacker internal immutable stacker;
    IERC20 internal immutable imd;
    uint256 internal constant CASHBACK = 1e18;

    constructor(ResolutionPool pool_, Stacker stacker_, IERC20 imd_) {
        pool = pool_;
        stacker = stacker_;
        imd = imd_;
        imd_.approve(address(stacker_), type(uint256).max);
    }

    function afterSwap(address sender, bytes calldata hookData, bool legacy) external {
        require(msg.sender == address(pool), "only pool");
        if (legacy) {
            address legacyTrader = hookData.length == 20 ? address(bytes20(hookData)) : sender;
            stacker.credit(legacyTrader, CASHBACK);
            return;
        }

        (address trader, bool stake) = resolve(sender, hookData);
        // An unsupported route has no known recipient. Do not guess or pay its router.
        if (trader == address(0)) return;
        if (stake) {
            require(gasleft() >= 410_000, "imd/acc: insufficient gas");
            try stacker.credit{gas: 350_000}(trader, CASHBACK) {
                return;
            } catch {}
        }
        require(imd.transfer(trader, CASHBACK));
    }

    function resolve(address sender, bytes calldata hookData)
        public
        view
        returns (address trader, bool stake)
    {
        if (hookData.length == 20) {
            trader = address(bytes20(hookData));
            if (_valid(trader, sender)) return (trader, true);
        }

        if (sender.code.length == 0) {
            trader = sender;
        } else {
            // Bounded gas and return data: reverting/malformed/expensive accessors cannot
            // force a credit to the router or consume the complete trade's gas budget.
            bytes memory input = abi.encodeWithSignature("msgSender()");
            bool ok;
            uint256 size;
            uint256 value;
            assembly ("memory-safe") {
                ok := staticcall(30000, sender, add(input, 32), mload(input), 0, 32)
                size := returndatasize()
                value := mload(0)
            }
            if (!ok || size != 32 || value > type(uint160).max) return (address(0), false);
            trader = address(uint160(value));
        }
        if (!_valid(trader, sender)) return (address(0), false);
        // Invalid nonempty data must not invent points; plain IMD goes to the known caller.
        return (trader, hookData.length == 0);
    }

    function _valid(address trader, address sender) internal view returns (bool) {
        return trader != address(0) && trader != address(stacker) && trader != address(imd)
            && trader != address(stacker.SIMD()) && !(trader == sender && sender.code.length != 0);
    }
}

contract TraderResolutionTest is BaseTest {
    ResolutionPool internal pool;
    ResolutionHook internal hook;
    ResolutionRouter internal router;
    address internal trader = makeAddr("router trader");
    address internal searcher = makeAddr("router searcher");

    function setUp() public override {
        super.setUp();
        pool = new ResolutionPool();
        hook = new ResolutionHook(pool, stacker, IERC20(address(imd)));
        router = new ResolutionRouter();
        deal(address(imd), address(hook), 10e18);
    }

    function test_legacyEmptyHookDataCreditsRouterAndAnyoneCanSweep() public {
        vm.recordLogs();
        vm.prank(trader);
        router.swap(pool, hook, "", true);
        uint256 shares = sImd.balanceOf(address(router));
        assertGt(shares, 0);
        assertEq(sImd.balanceOf(trader), 0);
        (uint256 amount, uint256 loggedShares) =
            stackedFromLogs(vm.getRecordedLogs(), address(hook), address(router));
        assertEq(amount, 1e18);
        assertEq(loggedShares, shares);
        vm.prank(searcher);
        router.sweep(IERC20(address(sImd)), searcher);
        assertEq(sImd.balanceOf(searcher), shares);
        assertEq(sImd.balanceOf(address(router)), 0);
    }

    function test_emptyHookDataResolvesActiveMsgSenderAndCannotBeSwept() public {
        vm.recordLogs();
        vm.prank(trader);
        router.swap(pool, hook, "", false);
        assertGt(sImd.balanceOf(trader), 0);
        assertEq(sImd.balanceOf(address(router)), 0);
        (uint256 amount,) = stackedFromLogs(vm.getRecordedLogs(), address(hook), trader);
        assertEq(amount, 1e18);
        vm.prank(searcher);
        router.sweep(IERC20(address(sImd)), searcher);
        assertEq(sImd.balanceOf(searcher), 0);
    }

    function test_hookDataTakesPrecedenceAndSupportsContractWallets() public {
        address wallet = makeAddr("contract wallet");
        vm.etch(wallet, hex"00");
        vm.prank(trader);
        router.swap(pool, hook, abi.encodePacked(wallet), false);
        assertGt(sImd.balanceOf(wallet), 0);
        assertEq(sImd.balanceOf(trader), 0);
        assertEq(sImd.balanceOf(address(router)), 0);
        uint256 firstShares = sImd.balanceOf(wallet);
        vm.prank(wallet);
        router.swap(pool, hook, "", false);
        assertGt(sImd.balanceOf(wallet), firstShares, "contract caller context also works");
    }

    function test_directNoCodeSenderCanBeResolvedWithoutTxOrigin() public {
        vm.prank(trader, searcher);
        pool.swap(hook, "", false);
        assertGt(sImd.balanceOf(trader), 0);
        assertEq(sImd.balanceOf(searcher), 0);
    }

    function test_pausedVaultPaysPlainImdToResolvedMsgSender() public {
        vm.prank(OWNER);
        sImd.setPaused(true);
        vm.prank(trader);
        router.swap(pool, hook, "", false);
        _assertPlainImd(1e18);
    }

    function test_invalidHookDataPaysPlainImdToKnownCallerNeverInvalidRecipient() public {
        address[5] memory invalid =
            [address(0), address(stacker), address(sImd), address(imd), address(router)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(trader);
            router.swap(pool, hook, abi.encodePacked(invalid[i]), false);
            _assertPlainImd((i + 1) * 1e18);
        }
        vm.prank(trader);
        router.swap(pool, hook, hex"1234", false);
        _assertPlainImd(6e18);
    }

    function test_unknownContractOrInvalidMsgSenderNeverBecomesTheRecipient() public {
        address unknown = makeAddr("unsupported router");
        bytes[8] memory runtime = [
            bytes(hex"00"), // no accessor / empty return data
            hex"5f5ffd", // revert
            hex"fe", // consumes the bounded accessor gas
            hex"60015f526001601ff3", // malformed one-byte return data
            hex"5f5f5260205ff3", // zero address returned as a word
            abi.encodePacked(hex"73", unknown, hex"5f5260205ff3"), // self-reference
            abi.encodePacked(hex"7f", bytes32(type(uint256).max), hex"5f5260205ff3"), // dirty high bits
            hex"5f5f5260405ff3" // too much return data
        ];
        for (uint256 i; i < runtime.length; ++i) {
            vm.etch(unknown, runtime[i]);
            vm.prank(unknown);
            pool.swap(hook, "", false);
            assertEq(sImd.balanceOf(unknown), 0);
            assertEq(imd.balanceOf(unknown), 0);
        }
        assertEq(imd.balanceOf(address(hook)), 10e18);
        assertEq(stacker.totalStacked(), 0);
        // Outside an active router execution, msgSender is zero: do not use the router itself.
        (address recipient, bool stake) = hook.resolve(address(router), "");
        assertEq(recipient, address(0));
        assertFalse(stake);
    }

    function _assertPlainImd(uint256 amount) internal view {
        assertEq(imd.balanceOf(trader), amount);
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(sImd.balanceOf(trader), 0);
        assertEq(sImd.balanceOf(address(router)), 0);
        assertEq(stacker.totalStacked(), 0);
        assertEq(imd.allowance(address(stacker), address(sImd)), 0);
    }
}
