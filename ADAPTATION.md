# Robinhood Chain ProjectRegistry launch adaptation

This prepares the single `ProjectRegistry` in the existing `launch.json` for the
launch service. No transaction was broadcast. The manifest, build configuration,
dependencies, `src/oracle/OracleAttestation.sol`, and all other production
contracts are unchanged. No token, Stacker, RemoteStacker, StackReceiver, workflow,
owner, initializer, proxy, or deployment dependency was added.

The assignment requires fixing reproduced imported audit findings and expressly
allows the corresponding behavior changes. The two fixes below are the only
production changes. **The resulting registry is not byte-for-byte identical to
mainnet launch #1495:** its runtime is 23,709 bytes, versus the supplied baseline
of 23,427 bytes. The manifest step should describe these two audit fixes in its
notes rather than claim exact mainnet bytecode parity; this step has not edited
`launch.json`.

## Launch wiring

The existing manifest already contains exactly the required deployment, with
seven static constructor arguments in this order:

| Argument | Value |
| --- | --- |
| intake | `0xa43e6f75ee006411f79ac1c84120606c2330de82` (Intake v2) |
| oracleAsset | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (Robinhood IMD) |
| stacker | `0x4de07c2fa46d5d6ed9ceb3f38ec56d3461b3e898` (live RemoteStacker, #1537) |
| oracleSigner | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| questionChainId | `4663` |
| challengeBond | `20000000000000000000` (20 IMD) |
| challengeCooldown | `604800` (7 days) |

The nonpayable constructor still only configures the registry. It performs no
external calls and needs no dependency code, including ArbSys, to exist during
the empty-chain factory rehearsal. The RemoteStacker is named in questions and
never called. The existing Ethereum receiver is not deployed or changed.

## Changes and reproduced findings

| File | Change and reason |
| --- | --- |
| `src/ProjectRegistry.sol` | Read the Robinhood rollup height through ArbSys only when starting or ending a listing; reject `claimBond(address(this))`. These fix the two reproduced audit findings below. |
| `test/RegistryRobinhoodBlocks.t.sol` | Regression tests for storage/event boundaries, points before and after delisting, relisting within one parent block, fuzzed periods, unchanged mainnet/Sepolia block semantics, unavailable/malformed ArbSys, cold 200,000-gas callbacks including owed bonds, accepted self-challenges, and Robinhood question wiring without RemoteStacker calls. |
| `test/mocks/MockArbSys.sol` | Test-only rollup-height model, independent of `block.number`; no production deployment or external dependency. |
| `test/RegistryBondOwed.t.sol` | Reproduce a refused payout followed by a self-directed claim; assert rejection preserves the debt and a later valid claim recovers it. |
| `test/RegistryRobinhoodLaunch.t.sol` | Rehearse the exact existing manifest through CREATE2 on empty chain 4663. Check arguments, one creation, no external constructor operations, no children, no owner, canonical callback selectors, size limits and forbidden runtime opcodes. |
| `ADAPTATION.md` | Record changes, evidence, accepted limits and verification required by this assignment. |

### d118fc17bdaed2cdd6fd544de471c0a3ed57566d00de0b39a0ccb8daa2a489bd — reproduced and fixed

The original contract writes `uint64(block.number)` into both listing boundaries
and events. The supplied chain reference and audit identify this as Ethereum's
parent height on Robinhood, whereas credit logs use the rollup height. The
snapshot builder compares credit log block numbers with those event fields, and
the app reads the same fields from `projectOf`.

Before the source change, the regression's listing event failed with
`expected=87470000, got=26183281`; the delisting/relisting test likewise recorded
`26233281` instead of `87600000`. These are deterministic local reproductions
with independently modeled parent and rollup heights, not new live observations.

The fix implements audit option (a): on execution chain 4663,
`_listingBlockNumber()` reads
`IRegistryArbSys(0x0000000000000000000000000000000000000064).arbBlockNumber()`.
Other chains retain `block.number`. The selection uses the execution chain,
not the oracle's question chain. Each transition reads once and emits the same
value that it stores. No ABI or storage-layout change is needed, and neither
the indexer nor direct storage consumers need a special interpretation.

The tests enforce the existing half-open period `[fromBlock, toBlock)`: credits
before listing earn nothing, credits within a listing retain their points after
delisting, and credits at/after delisting earn nothing. Separate rollup blocks
remain distinguishable within a single parent block. Rejections, defenses,
failures and expiry do not consult ArbSys. A failed or malformed ArbSys response
reverts the entire callback instead of silently recording a parent height; the
existing completed-request/one-day expiry path still clears the request and
returns its bond. The constructor never reads ArbSys.

### 5e9e31497c766fbabf3982fa29a27a687054c51913be07168694ed6b96981006 — reproduced and fixed

With a token refusing the challenger's refund, the original registry correctly
records `bondOwed`. Once transfers are enabled, however, its self-directed claim
succeeds: it clears the debt and performs a token self-transfer, leaving the
balance stranded. Before the change the regression failed with
`next call did not revert as expected`.

`claimBond` now rejects the registry itself with the existing
`InvalidBeneficiary` error before changing the debt, matching `applyListing` and
`setBeneficiary`. Zero-address rejection remains unchanged. Tests verify that
the owed bond survives rejection, is still backed by the token balance, and can
subsequently be claimed to a usable wallet. The Robinhood cold-callback test also
covers a 20 IMD debt created by a delisting under the 200,000-gas stipend.

### 353e9b420b2b1d6563ff11e92ce2a491d9fcb462bd599f89e0214bfb0f19f349 — accepted limits, unchanged

These are the brief's accepted design limits, not defects to redesign:

1. A listed project's beneficiary can hold its question slot with a challenge
   after cooldown. A defense returns the bond to the beneficiary, costs the live
   oracle fee, and does not restart cooldown. Each round judges the project
   again and buys no immunity. Existing tests and the new Robinhood regression
   exercise this behavior.
2. Anyone can occupy an ownerless project's application slot for the fee per
   round. The existing 30,000-gas, at-most-32-byte `owner()` read treats reverts,
   malformed/zero answers and gas exhaustion as no owner. An owned project still
   admits only its reported owner or the project itself, before charging a fee.
   Existing applicant-gate and open-question tests cover these paths.
3. There is no owner. Intake, asset, signer, action and panel constants are fixed
   for life; rotation or migration requires another registry. This intentionally
   overrides the generic oracle reference's owner-settable example.
   `ORACLE_FEE()` alone reads the current `priceOf` for each ask. Panel rules 3.1,
   all eight definitions, 15 seats/11 agreement, the one-day handoff limit and
   request expiry, and the 300-second signature tolerance are unchanged.
4. The registry trusts the Intake writer to pair a signed answer with the correct
   open Intake request. It does not pin `questionHash`. Signatures remain bound
   to this consumer's EIP-712 domain, and the registry checks the sender, its own
   open request, signature freshness, question chain, panel and replay key.
5. Unsigned failure notifications only clear requests and return bonds; they
   never list or delist. A withheld answer can likewise be cleared after one day,
   or when the Intake reports completion. Late callbacks cannot settle a cleared
   request. The existing failure, expiry, replay and bond tests remain passing.
6. The brief/audit supply the live Robinhood Intake's 0.5 IMD price, 200,000-gas
   callback budget, and seven-word `requests` response compatible with the
   registry's first-four-word read. They also supply the RemoteStacker's live
   wiring and differing Intake runtime hashes across chains. These observations
   were not independently refreshed: the read-only public Robinhood RPC probe
   returned **HTTP 403 Forbidden**. No claim of fresh live/fork verification is
   made, and no deployment addresses were invented.

Neither actionable finding was dismissed as non-reproducible. The informational
finding's contract behavior was confirmed by source review and local tests; its
live-network observations remain supplied evidence because of the RPC response.

## Verification

- Baseline: `forge build` passed; `forge test` passed 346 tests, with 29 skipped.
- Before fixes: both new block-boundary regressions and the self-claim regression
  failed against the original source. All three passed after the source change.
- Final: `forge build` passed; `forge test` passed **360 tests, zero failures,
  29 skipped** across 57 suites. The skips are 24 existing opt-in fork tests and
  5 existing tests for other branches' launch manifests. No new test skips.
- The default suite includes fuzzing (256 runs) and the existing invariant
  campaigns (64 runs, depth 32). New cold listing, delisting/refund and
  delisting/owed-bond callbacks all succeed with exactly 200,000 gas forwarded.
- The exact-manifest rehearsal creates one registry with a 23,709-byte runtime,
  under EIP-170's 24,576-byte limit, and checks the initcode limit and absence of
  DELEGATECALL, CALLCODE and SELFDESTRUCT.
- Toolchain used: installed Forge 1.5.1 and Solidity 0.8.26, with the project's
  unchanged Cancun target, 10,000 optimizer runs and `bytecode_hash = "none"`.
  No dependencies were installed. Slither/Mythril and live deployment were not
  run. All delivered tests work without network access or secrets.

The local build/test results are reproducibility evidence for the next review,
not an independent audit or a deployment attestation.
