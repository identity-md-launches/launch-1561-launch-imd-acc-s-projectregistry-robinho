// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {ERC4626} from "solady/tokens/ERC4626.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {BaseTest} from "./Base.t.sol";
import {TestIMD} from "./mocks/TestIMD.sol";
import {TestSIMD} from "./mocks/TestSIMD.sol";
import {Stacker} from "src/Stacker.sol";

/// @dev A closed, funded world with the vault renounced from the start, as on mainnet. Unlike
/// handlers that always roll before redeeming, exits here run in the current block. Positive
/// mints and transfers maintain an independent model of each holder's earliest exit block.
contract StackerHoldHandler is Test {
    TestIMD public immutable imd;
    TestSIMD public immutable vault;
    Stacker public immutable stacker;
    address public immutable formerOwner;
    address[4] public actors;

    mapping(address => uint256) public ghostImd;
    mapping(address => uint256) public ghostShares;
    mapping(address => uint256) public ghostHold;
    mapping(address => uint256) public ghostProjectAssets;
    mapping(address => uint256) public ghostProjectShares;
    uint256 public ghostDeposited;
    uint256 public ghostMinted;
    uint256 public ghostBurned;
    uint256 public ghostRedeemed;
    uint256 public ghostDonated;
    uint256 public heldExitFailures;
    uint256 public unauthorizedExitFailures;
    uint256 public zeroShareFailures;
    uint256 public successfulExits;

    constructor(TestIMD imd_, TestSIMD vault_, Stacker stacker_, address formerOwner_) {
        imd = imd_;
        vault = vault_;
        stacker = stacker_;
        formerOwner = formerOwner_;
        for (uint256 i; i < actors.length; ++i) {
            address actor = makeAddr(string.concat("hold actor ", vm.toString(i)));
            actors[i] = actor;
            vm.startPrank(actor);
            imd.faucet();
            imd.approve(address(stacker), type(uint256).max);
            imd.approve(address(vault), type(uint256).max);
            vm.stopPrank();
            ghostImd[actor] = imd.FAUCET_AMOUNT();
        }
    }

    function credit(uint256 payerSeed, uint256 receiverSeed, uint256 amount) external {
        address payer = actors[payerSeed % actors.length];
        address receiver = actors[receiverSeed % actors.length];
        amount = bound(amount, 0, ghostImd[payer]);
        if (amount > 0 && vault.previewDeposit(amount) == 0) {
            vm.prank(payer);
            vm.expectRevert(Stacker.ZeroShares.selector);
            stacker.credit(receiver, amount);
            zeroShareFailures++;
            return;
        }
        vm.prank(payer);
        uint256 shares = stacker.credit(receiver, amount);
        if (amount == 0) {
            assertEq(shares, 0);
            return;
        }
        assertGt(shares, 0);
        ghostImd[payer] -= amount;
        ghostShares[receiver] += shares;
        ghostHold[receiver] = block.number;
        ghostProjectAssets[payer] += amount;
        ghostProjectShares[payer] += shares;
        ghostDeposited += amount;
        ghostMinted += shares;
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount, bool delegated)
        external
    {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = bound(amount, 0, ghostShares[from]);
        if (delegated) {
            vm.prank(from);
            vault.approve(address(this), amount);
            vault.transferFrom(from, to, amount);
            assertEq(vault.allowance(from, address(this)), 0, "exact share allowance consumed");
        } else {
            vm.prank(from);
            vault.transfer(to, amount);
        }
        ghostShares[from] -= amount;
        ghostShares[to] += amount;
        if (amount > 0 && ghostHold[from] > ghostHold[to]) ghostHold[to] = ghostHold[from];
    }

    function exit(
        uint256 ownerSeed,
        uint256 receiverSeed,
        uint256 amount,
        bool withdrawAssets,
        bool delegated
    ) external {
        address owner = actors[ownerSeed % actors.length];
        address receiver = actors[receiverSeed % actors.length];
        uint256 limit =
            withdrawAssets ? vault.convertToAssets(ghostShares[owner]) : ghostShares[owner];
        if (limit == 0) return;
        amount = bound(amount, 1, limit);
        uint256 shareCost = withdrawAssets ? vault.previewWithdraw(amount) : amount;
        if (delegated) {
            vm.prank(owner);
            vault.approve(address(this), shareCost);
        }
        if (ghostHold[owner] == block.number) {
            if (!delegated) vm.prank(owner);
            vm.expectRevert(
                withdrawAssets
                    ? ERC4626.WithdrawMoreThanMax.selector
                    : ERC4626.RedeemMoreThanMax.selector
            );
            if (withdrawAssets) vault.withdraw(amount, receiver, owner);
            else vault.redeem(amount, receiver, owner);
            if (delegated) {
                assertEq(
                    vault.allowance(owner, address(this)), shareCost, "hold failure spent approval"
                );
                vm.prank(owner);
                vault.approve(address(this), 0);
            }
            heldExitFailures++;
            return;
        }
        if (!delegated) vm.prank(owner);
        uint256 returned = withdrawAssets
            ? vault.withdraw(amount, receiver, owner)
            : vault.redeem(amount, receiver, owner);
        uint256 assets = withdrawAssets ? amount : returned;
        uint256 shares = withdrawAssets ? returned : amount;
        if (delegated) assertEq(vault.allowance(owner, address(this)), 0);
        _recordExit(owner, receiver, assets, shares);
    }

    function unauthorizedExit(uint256 ownerSeed, uint256 receiverSeed) external {
        address owner = actors[ownerSeed % actors.length];
        uint256 shares = ghostShares[owner];
        if (shares == 0) return;
        assertEq(vault.allowance(owner, address(this)), 0);
        vm.expectRevert(
            ghostHold[owner] == block.number
                ? ERC4626.RedeemMoreThanMax.selector
                : ERC20.InsufficientAllowance.selector
        );
        vault.redeem(shares, actors[receiverSeed % actors.length], owner);
        unauthorizedExitFailures++;
    }

    /// @dev None of these zero actions may relock mature shares or prime the Stacker's approval.
    function zeroAction(uint256 fromSeed, uint256 toSeed, uint8 action) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        vm.startPrank(from);
        if (action % 4 == 0) assertEq(stacker.credit(to, 0), 0);
        else if (action % 4 == 1) assertEq(vault.deposit(0, to), 0);
        else if (action % 4 == 2) assertEq(vault.mint(0, to), 0);
        else vault.transfer(to, 0);
        vm.stopPrank();
    }

    function donate(uint256 payerSeed, uint256 amount) external {
        address payer = actors[payerSeed % actors.length];
        amount = bound(amount, 0, ghostImd[payer]);
        vm.prank(payer);
        imd.transfer(address(vault), amount);
        ghostImd[payer] -= amount;
        ghostDonated += amount;
    }

    function advance(uint256 distance, bool mineBlock) external {
        distance = bound(distance, 1, 10);
        // Changing only the timestamp must not clear a hold keyed to block.number.
        vm.warp(block.timestamp + distance * 12);
        if (mineBlock) vm.roll(block.number + distance);
    }

    function probeRenouncedPowers(uint256 callerSeed, uint8 operation) external {
        address caller = callerSeed % 5 == 4 ? formerOwner : actors[callerSeed % actors.length];
        vm.prank(caller);
        vm.expectRevert(Ownable.Unauthorized.selector);
        if (operation % 3 == 0) vault.setPaused(true);
        else if (operation % 3 == 1) vault.rescueERC20(address(imd), caller, 1);
        else vault.transferOwnership(caller);
    }

    /// @dev Called by afterInvariant, excluded from the random selector list. Every reachable
    /// holder must be able to redeem in full once one block has elapsed, including dust shares.
    function drainAll() external {
        vm.roll(block.number + 1);
        for (uint256 i; i < actors.length; ++i) {
            address owner = actors[i];
            uint256 shares = ghostShares[owner];
            if (shares == 0) continue;
            vm.prank(owner);
            uint256 assets = vault.redeem(shares, owner, owner);
            _recordExit(owner, owner, assets, shares);
        }
    }

    function _recordExit(address owner, address receiver, uint256 assets, uint256 shares) internal {
        ghostShares[owner] -= shares;
        ghostImd[receiver] += assets;
        ghostRedeemed += assets;
        ghostBurned += shares;
        successfulExits++;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract StackerHoldInvariantTest is StdInvariant, BaseTest {
    StackerHoldHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.chainId(1);
        vm.prank(OWNER);
        sImd.renounceOwnership();
        handler = new StackerHoldHandler(imd, sImd, stacker, OWNER);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = StackerHoldHandler.credit.selector;
        selectors[1] = StackerHoldHandler.transferShares.selector;
        selectors[2] = StackerHoldHandler.exit.selector;
        selectors[3] = StackerHoldHandler.unauthorizedExit.selector;
        selectors[4] = StackerHoldHandler.zeroAction.selector;
        selectors[5] = StackerHoldHandler.donate.selector;
        selectors[6] = StackerHoldHandler.advance.selector;
        selectors[7] = StackerHoldHandler.probeRenouncedPowers.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_balancesAndHistoricalCashbackAreConserved() public view {
        uint256 circulating;
        uint256 outstandingShares;
        uint256 projectAssets;
        uint256 projectShares;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(imd.balanceOf(actor), handler.ghostImd(actor), "actor IMD ledger");
            assertEq(sImd.balanceOf(actor), handler.ghostShares(actor), "actor share ledger");
            assertEq(stacker.projectStacked(actor), handler.ghostProjectAssets(actor));
            assertEq(stacker.projectShares(actor), handler.ghostProjectShares(actor));
            circulating += imd.balanceOf(actor);
            outstandingShares += sImd.balanceOf(actor);
            projectAssets += stacker.projectStacked(actor);
            projectShares += stacker.projectShares(actor);
        }
        uint256 vaultAssets =
            handler.ghostDeposited() + handler.ghostDonated() - handler.ghostRedeemed();
        assertEq(sImd.totalAssets(), vaultAssets);
        assertEq(imd.totalSupply(), 4 * imd.FAUCET_AMOUNT(), "fixed funded supply");
        assertEq(circulating + vaultAssets, imd.totalSupply(), "every IMD wei accounted for");
        assertEq(sImd.totalSupply(), outstandingShares);
        assertEq(outstandingShares, handler.ghostMinted() - handler.ghostBurned());
        assertEq(projectAssets, handler.ghostDeposited());
        assertEq(stacker.totalStacked(), projectAssets, "exits never undo historical credits");
        assertEq(projectShares, handler.ghostMinted());
        assertEq(imd.balanceOf(address(stacker)), 0);
        assertEq(sImd.balanceOf(address(stacker)), 0);
        assertEq(
            imd.allowance(address(stacker), address(sImd)),
            handler.ghostDeposited() == 0 ? 0 : type(uint256).max
        );
    }

    function invariant_holdFollowsSharesAndCannotBeClearedByTimestamp() public view {
        assertEq(sImd.owner(), address(0));
        assertFalse(sImd.paused());
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 hold = handler.ghostHold(actor);
            uint256 shares = handler.ghostShares(actor);
            assertEq(sImd.lastDepositBlock(actor), hold, "hold disagrees with transfer history");
            assertEq(sImd.maxRedeem(actor), hold == block.number ? 0 : shares);
            assertEq(
                sImd.maxWithdraw(actor), hold == block.number ? 0 : sImd.convertToAssets(shares)
            );
            assertEq(sImd.allowance(actor, address(handler)), 0, "no leftover delegated authority");
        }
    }

    function afterInvariant() public {
        handler.drainAll();
        assertEq(sImd.totalSupply(), 0, "all mature shares must remain redeemable");
        invariant_balancesAndHistoricalCashbackAreConserved();
        invariant_holdFollowsSharesAndCannotBeClearedByTimestamp();
    }

    function test_handlerExercisesHeldDelegatedAndMatureExits() public {
        handler.credit(0, 1, 10e18);
        handler.transferShares(1, 2, 2e24, true);
        handler.exit(2, 3, 1e24, false, true);
        handler.advance(1, false);
        handler.exit(1, 0, 1e18, true, false);
        assertEq(handler.heldExitFailures(), 2);
        handler.advance(1, true);
        for (uint8 i; i < 4; ++i) {
            handler.zeroAction(0, 1, i);
        }
        handler.unauthorizedExit(1, 0);
        assertEq(handler.unauthorizedExitFailures(), 1);
        handler.exit(1, 0, 1e18, true, true);
        handler.exit(2, 3, 1e24, false, true);
        assertEq(handler.successfulExits(), 2);
        // Mature shares cannot clear a receiver's more recent hold.
        handler.credit(0, 2, 1e18);
        handler.transferShares(1, 2, 1e24, false);
        handler.exit(2, 3, 1e24, false, false);
        assertEq(handler.heldExitFailures(), 3);
        for (uint8 i; i < 3; ++i) {
            handler.probeRenouncedPowers(4, i);
        }
        invariant_balancesAndHistoricalCashbackAreConserved();
        invariant_holdFollowsSharesAndCannotBeClearedByTimestamp();
        afterInvariant();
    }

    function test_handlerExercisesZeroSharesFailureBeforeInitialization() public {
        handler.donate(0, 1e18);
        handler.credit(1, 2, 1);
        assertEq(handler.zeroShareFailures(), 1);
        assertEq(stacker.totalStacked(), 0);
        invariant_balancesAndHistoricalCashbackAreConserved();
        invariant_holdFollowsSharesAndCannotBeClearedByTimestamp();
        handler.credit(1, 2, 10e18);
        assertGt(stacker.totalStacked(), 0);
        afterInvariant();
    }
}
