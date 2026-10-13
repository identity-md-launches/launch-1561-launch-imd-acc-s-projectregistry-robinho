// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev The two vault functions the Stacker uses (ERC-4626 subset).
interface IStakedIMD {
    function asset() external view returns (address);
    function deposit(uint256 assets, address to) external returns (uint256 shares);
}

/// @title Stacker
/// @notice imd/acc cashback funnel. A project that wants to pay a trader cashback in staked IMD calls
/// `credit(trader, imdAmount)`: the Stacker pulls `imdAmount` IMD from the project (msg.sender),
/// deposits it into the sIMD vault with the trader as the share recipient, and emits `Stacked`.
/// The project funds the cashback from its own existing fees; the Stacker takes no fee, has no owner
/// or admin, and holds no IMD or sIMD between calls.
///
/// Per-trader figures (cashback received, points, shares from cashback) come from the `Stacked`
/// events, which record project, trader, IMD and shares for every credit. The contract keeps only
/// per-project totals and the grand total on chain, so a credit writes no new storage per trader.
///
/// Integrators are expected to wrap `credit` in try/catch: it reverts (and moves nothing) when the
/// vault refuses the deposit, when the project's allowance or balance is short, or when the trader
/// is zero, the Stacker itself, the IMD token, or the vault itself.
contract Stacker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The IMD token the vault stakes (the vault's `asset()`).
    IERC20 public immutable IMD;
    /// @notice The staked-IMD ERC-4626 vault that receives every deposit.
    IStakedIMD public immutable SIMD;
    bool private _vaultReady;

    /// @notice IMD stacked by each project, across all traders.
    mapping(address => uint256) public projectStacked;
    /// @notice sIMD shares minted through each project.
    mapping(address => uint256) public projectShares;
    /// @notice IMD stacked through this contract in total.
    uint256 public totalStacked;

    /// @notice Emitted once per successful non-zero credit. This is the record points are built from.
    /// @param project The caller that funded the cashback.
    /// @param trader The address that received the sIMD shares.
    /// @param imd IMD pulled from the project and deposited.
    /// @param shares sIMD shares minted to the trader.
    event Stacked(address indexed project, address indexed trader, uint256 imd, uint256 shares);

    /// @notice `credit` was called with the zero address as trader.
    error ZeroTrader();
    /// @notice Shares sent to the Stacker, IMD token or vault itself would be irrecoverable.
    error InvalidTrader();
    /// @notice The vault's `asset()` is not the IMD address given to the constructor.
    error AssetMismatch(address vaultAsset, address imd);
    /// @notice The vault minted no shares for a non-zero deposit (would silently lose the IMD).
    error ZeroShares();

    /// @param imd The IMD token.
    /// @param sImd The staked-IMD vault; its `asset()` must equal `imd`.
    /// @dev No external calls: the factory also rehearses deployment on an empty chain. The first
    /// non-zero credit checks the live vault and approves it before pulling any caller's tokens.
    constructor(IERC20 imd, IStakedIMD sImd) {
        IMD = imd;
        SIMD = sImd;
    }

    /// @notice Pull `imdAmount` IMD from the caller and stake it for `trader`; the sIMD shares are
    /// minted directly to `trader`. Returns the shares minted.
    /// @dev Reverts with `ZeroTrader` for a zero trader, or `InvalidTrader` for this contract,
    /// the IMD token or vault. Returns 0 (no transfer, no event, no state change) for a zero amount
    /// and a valid trader. Bubbles up the vault's and token's errors unchanged.
    function credit(address trader, uint256 imdAmount)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (trader == address(0)) revert ZeroTrader();
        if (trader == address(this) || trader == address(SIMD) || trader == address(IMD)) {
            revert InvalidTrader();
        }
        if (imdAmount == 0) return 0;

        if (!_vaultReady) {
            address vaultAsset = SIMD.asset();
            if (vaultAsset != address(IMD)) revert AssetMismatch(vaultAsset, address(IMD));
            _vaultReady = true;
            // Preserve the one-time approval to this immutable vault. Failed credits roll back
            // both the approval and this flag, so validation is retried on the next credit.
            IMD.forceApprove(address(SIMD), type(uint256).max);
        }

        IMD.safeTransferFrom(msg.sender, address(this), imdAmount);
        shares = SIMD.deposit(imdAmount, trader);
        if (shares == 0) revert ZeroShares();

        projectStacked[msg.sender] += imdAmount;
        projectShares[msg.sender] += shares;
        totalStacked += imdAmount;

        emit Stacked(msg.sender, trader, imdAmount, shares);
    }
}
