# For the PLEA session: what changed in imd/acc (2026-10-12)

imd/acc moved on today; four things affect PLEA.

## 1. Addresses

- **Mainnet Stacker (live, launch #1409):** `0x06909f672301f28a810f78cfe7a754851269f4f0`, on IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` and sIMD `0x9efa934d9fad4ae28c998a40195646b965a97247`. Already primed (the vault approval is set), so PLEA's first credit costs the normal amount. Source verified on Sourcify and Blockscout. It refuses the Stacker, the vault and the IMD token as the trader (`InvalidTrader`).
- **Sepolia:** the Stacker is unchanged (`0x0457276d7b036818b3eddc1a4a3fceda61e9314d`). The current registry is **test run 5, `0x5f63cdead0f5f693b8964d82b56155f55645ccea`** (launch #1428). PLEA's listing on test run 4 (`0xfe44…d102`) stays in that registry's history but no longer counts on the site.
- **Mainnet registry:** not deployed yet. Same code as test run 5, bond 20 IMD, cooldown 7 days. Points only count from the block a project is listed, so the aim is to have it live before PLEA trades on mainnet.

## 2. The trader rule (version 3): the change PLEA needs

In a Uniswap v4 hook, `sender` is usually the router, not the person. The panel now checks: valid router `hookData` first; else the router's `msgSender()` during the swap; else `sender` only if it has no code; never `tx.origin`; never a router. If no trader can be resolved, skip the cashback (the trade still goes through).

PleaHook today (`beforeSwap`, around line 436 of the Sepolia hook `0x2d5a…a8cc`): buys require `hookData` (good), but sells fall back to `trader = sender`. When a router is the sender, the cashback goes to the router, and anyone can sweep the Universal Router's balance. On test run 5, SelfCredit was just rejected 11 of 11 with this exact rule cited, so PLEA's current hook would likely get a "no".

Suggested resolution, adapted from IMD's tested reference (`test/TraderResolution.t.sol` in khaed1/imd-acc) to PLEA's 32-byte `abi.encode(address)` hookData:

```solidity
/// @return trader zero means: skip the cashback, never pay the router
/// @return stake  false means: pay plain IMD instead of crediting (bad hookData)
function _resolveTrader(address sender, bytes calldata hookData)
    internal view returns (address trader, bool stake)
{
    if (hookData.length == 32) {
        trader = abi.decode(hookData, (address));
        if (_validTrader(trader, sender)) return (trader, true);
    }
    if (sender.code.length == 0) {
        trader = sender; // a plain wallet called the PoolManager itself
    } else {
        // The router's active caller, with bounded gas and at most 32 bytes read.
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
    if (!_validTrader(trader, sender)) return (address(0), false);
    return (trader, hookData.length == 0); // invalid hookData: plain IMD to the caller, no credit
}

function _validTrader(address t, address sender) internal view returns (bool) {
    // IMD_TOKEN and SIMD_VAULT: the hook's own IMD and sIMD addresses.
    return t != address(0) && t != address(stacker) && t != IMD_TOKEN && t != SIMD_VAULT
        && !(t == sender && sender.code.length != 0);
}
```

If sells come through PLEA's gate contract, the gate should pass the seller in `hookData` (or expose `msgSender()`), so sells resolve to the person, not the gate.

## 3. Gas budget

Check `gasleft() >= 410_000` before the call, then `try stacker.credit{gas: 350_000}(trader, cashback)`; on catch, pay plain IMD to the same resolved trader. Keep the check outside the `try/catch`. On Sepolia, new storage costs more, so PLEA's existing `creditGas + SWAP_RESERVE` check can stay higher there.

## 4. Listing rules that touch PLEA

- **Fee guard (version 3):** LP fees don't count as leaving. PLEA's split still passes: the locked pool share, the burn and the prizes leave for good (0.75% ≥ 0.5% cashback).
- **The only "no" votes on PLEA so far** (two version 2 panels, each reaching exactly the 11 needed): the public `rebalance()` pays a 0.01 IMD keeper tip from the reserve built from the pool share, and the owner can win Seasons prizes. Paying the tip from the owner's share (or dropping it) and excluding owner and team wallets from prizes would make the yes safer.
- **Only the hook's `owner()`, or the hook itself, can apply.** Keep `owner()` a wallet that can send transactions until PLEA is listed (not renounced, not a burn address). The beneficiary must be that owner or a team wallet named in the verified source or the official website.
- **Verify the hook's source** (Sourcify, Blockscout or Etherscan) before applying.

## Next

When the new Sepolia hook is deployed and verified, send its address to the owner. The imd/acc session prepares the application to test run 5 (applicant: the hook's owner) and asks the owner before sending. The test wallet `0x4b91…6821` is shared by both sessions: say so before sending transactions from it.

References in khaed1/imd-acc: README "Integrating a project" (rules 3 to 5), `docs/panel-rules-v2.md` (version 3), `test/TraderResolution.t.sol`.
