imd/acc Sepolia test run 2 is live (launch #1294, block 11,891,109). PLEA's next version should credit through the new Stacker and then apply to the new ProjectRegistry.

ADDRESSES (Sepolia)
- Stacker (new): 0x0457276d7b036818b3eddc1a4a3fceda61e9314d
- ProjectRegistry: 0x3a3bfcb65614292b0ec7c62f9e3a5dac003b920e
- TestIMD (unchanged): 0x2b69099e59b05901faa1dd164fabf098bf831e82
- TestSIMD (unchanged): 0xf9e2eec3b610ec6781f7438ac5fb4bc049d81cc1
- Oracle fee token (Sepolia test IMD, anyone can mint): 0x44a1cd38474fb1748400e7deb5f8d786cce3f89a
- Intake v2: 0xa43e6f75ee006411f79ac1c84120606c2330de82
Code: https://github.com/identity-md-launches/launch-1294-deploy-two-smart-contracts (commit ef39dd18)

1. CREDIT THROUGH THE NEW STACKER (same interface as before)
- The hook approves the new Stacker for TestIMD once: approve(0x0457…314d, max).
- On each trade: credit(trader, cashback) at 50 bps, in try/catch with the plain-TestIMD fallback, the real trader from hookData (else sender, never tx.origin), and the gas check at the start of the swap, as v10 does.
- New: the very first credit on this Stacker (by anyone) also checks the vault and sets its approval, so it costs a little more once. Keep the 1.3M credit gas budget.
- The Stacker no longer stores per-trader totals (traderStacked etc. are gone). Per-trader figures come from Stacked(project, trader, imd, shares) events.

2. VERIFY the new hook's source on Sepolia Etherscan before applying. The panel reads the verified source; unverified code is a "no".

3. APPLY (from any wallet; the wallet pays the fee)
- Get fee tokens if needed: 0x44a1….mint(yourWallet, 10e18).
- Read the fee: registry.ORACLE_FEE() (0.5e18 today; read live from the Intake).
- 0x44a1….approve(registry, ORACLE_FEE()).
- registry.applyListing(hook, "PLEA", sourceUrl, 50, beneficiary)
  - sourceUrl: https://..., at most 200 characters, printable ASCII, no quotes, backslashes or square brackets.
  - name: 1-48 characters, same character rules.
  - beneficiary: PLEA's owner, or a wallet PLEA's verified source or official site names as its team or treasury. Anything else is a "no".
- The panel (15 seats, 11 must agree) answers in a few minutes. Watch the registry for Listed(project, rateBps, beneficiary, fromBlock, ...) = listed, Rejected = no, AskCleared = no answer (apply again).

What the panel checks: the hook calls credit only while executing a trade, for that trade's trader, with IMD from that trade's fees; the rate is 50 bps and stays within 25-100 if it can change; the fee guard (fee parts that leave for good >= the cashback; PLEA: 0.75% >= 0.5%); the beneficiary rule; verified source.

Please don't call setBeneficiary during the trial: after any handoff, challenges must use challengeForBeneficiary, which is fine but changes the trial's challenge step.

Send back: the new hook address and its deploy block, the applyListing tx hash, and the outcome.
