# Mainnet Stacker regression coverage

These additions build on the existing tests without changing application contracts,
the manifest, dependencies, or configuration. They run offline with the dependencies
already in the repository. The factory is a local test fixture; nothing is broadcast.

| File | Additional coverage |
| --- | --- |
| `MainnetLaunchRegression.t.sol` | Requires exactly one `Stacker` with the two mainnet addresses in their specified order. Deploys creation code assembled from those manifest arguments through CREATE2 on an empty chain. Checks the predicted address, deployment nonces, constructor wiring, init/runtime limits, forbidden opcodes, and a zero credit without dependencies. This supplements the existing deployment test that also accepts historical Sepolia launch shapes. |
| `StackerDependencyFailures.t.sol` | Rejects false and invalid boolean token responses, bubbles token and asset-query errors, and rejects short or malformed vault responses. Covers both the project's transfer to Stacker and the vault's pull from Stacker, including the latter's wrapped error. Real token transfers and share mints occur before selected injected failures. A state snapshot checks rollback of balances, finite allowances, vault approval, share supply, receiver hold and accounting. A subsequent mismatched asset query proves that failed first credits did not retain readiness; a valid retry proves recovery. |
| `StackerGas.t.sol` | Extends the existing bounded-call integration tests with a vault that fails after transferring IMD and minting shares. First and repeat credits pay plain IMD exactly once, preserve prior shares and mature exit limits, and keep fallback payments out of Stacker accounting. A subsequent credit spends the remaining project balance successfully within the same gas budget. |
| `StackerHoldInvariant.t.sol` | Runs random credits, direct/delegated share transfers, direct/delegated exits, unauthorized exits, zero-value actions, donations, time/block advances, and attempts to use renounced privileges. Exits attempt the current block rather than advancing it first. Independent per-actor ledgers and hold histories track the expected results. |

The failure fuzz tests use 1,000 runs. The hold invariant uses 256 sequences of depth
64, `fail-on-revert`, and an explicit list of eight action selectors. Expected failures
have exact revert assertions; unexpected failures abort the campaign. Deterministic
handler tests exercise held and mature exits, allowance rejection, zero-share rejection,
time passing without blocks, inherited holds, zero actions, and the former owner's
removed privileges.

The invariant fixture funds four actors once through the existing test token's faucet,
then moves only that fixed supply. Actors can act as both projects and traders. It
checks each actor's IMD and shares, aggregate supply and vault assets, historical
project totals after redemptions, zero Stacker custody, first-use approval state,
and each holder's exit limits. After every campaign, every remaining share is redeemed
after one block, checking exit liveness as well as conservation. Donations and rounding
can leave assets belonging to virtual shares, so an empty share supply is not assumed
to imply an empty vault.

The vault is the existing `TestSIMD` source copy, renounced before the invariant starts
to model the ownership state given in the brief. Dependency failure doubles are fault
injection for atomicity tests, not assertions that live IMD has these behaviors. No
new test uses environment writes, network calls, FFI, or scratch-file imports.

Local checks, with disposable output confined to the allowed scratch directory:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

The existing optional mainnet and Sepolia fork tests still require their RPC settings.
An offline pass establishes local regression coverage; it does not independently
verify deployed bytecode or live chain state. Those fork runs remain owed when RPC
access is available.
