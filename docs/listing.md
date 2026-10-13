# Listing a project

Any project can use imd/acc: its traders get real sIMD from the first credit. **Listing** decides which projects' credits also earn **points**. There are two ways, depending on the chain:

- **On-chain ProjectRegistry, decided by an IdentityMD oracle panel:** from Sepolia test run 2 on. The project's owner applies with `applyListing` (anyone, for a project without an owner). See [below](#the-projectregistry-decided-by-an-imd-panel).
- **A list file in this repository:** for chains without a registry yet (mainnet until the Sepolia trial is done). Described first.

The checklist and the fee guard are the same either way: the file's reviewer and the oracle panel apply the same rules.

## A list file in this repository

One file per chain: [`listings/sepolia.json`](../listings/sepolia.json) now, `listings/mainnet.json` and others later. The test page fetches it from GitHub, so a listing takes effect when it is committed, with no paid job.

```json
[
  {
    "address": "0x…",
    "name": "PLEA",
    "fromBlock": 11885872,
    "rateBps": 50,
    "beneficiary": "0x…"
  }
]
```

| Field | Meaning |
|---|---|
| `address` | The contract that calls `Stacker.credit`, usually the project's hook. |
| `name` | Shown on the site. |
| `fromBlock` | Points count from this block on, never before. |
| `toBlock` | Optional, set only when a project is delisted: points stop at this block. Earlier points stay. |
| `rateBps` | The cashback rate the project applied with, in basis points, 25 to 100 (0.25% to 1%). The project may change it later within that range (see the checklist). |
| `beneficiary` | The wallet that holds the project's points, since a hook contract can't receive an airdrop. |

### Steps

1. **Integrate.** Call `Stacker.credit` inside the project's trades, following the [integration rules](../README.md#integrating-a-project): try/catch with a plain-IMD fallback, the real trader, a gas check.
2. **Verify** the contract source on the chain's explorer, so anyone can read it.
3. **Apply.** On a chain with a registry, call `applyListing` (or use the test page). Elsewhere, open a ["List my project" issue](https://github.com/khaed1/imd-acc/issues/new?template=listing-application.yml) with the address, rate, fee split and beneficiary.
4. **Review** against the checklist below.
5. **Decision** by the repository owner. If yes, the entry is committed and points start.

### Checklist

- [ ] The source is verified on the explorer.
- [ ] It calls `credit` only inside real trades, never with its own IMD for wallets it picks.
- [ ] The cashback is the stated `rateBps` of the trade, between 25 and 100.
- [ ] **Fee guard:** the part of the fee that really leaves for good is at least as large as the cashback; LP fees don't count (see below).
- [ ] If its rate or fees can change later, the limits are in the code: every allowed rate stays between 25 and 100, and every allowed setting keeps the fee guard. A change inside those limits keeps the listing.
- [ ] It resolves the real trader from valid router `hookData`, else the router's active `msgSender()`, else `sender` only if it has no code; never `tx.origin`. Validate destinations and use the same resolved trader for plain-IMD fallback. Invalid data may fall back to a separately resolved caller; an unknown router is never paid. Unsupported routes need trader data before cashback is enabled (README rule 3).
- [ ] A failed credit never blocks a trade: the trader gets plain IMD instead.
- [ ] It checks gas up front, so a wallet's gas estimate can't choose a path without cashback.

### The fee guard

A normal trader can't farm points: they pay the whole fee and get back only the cashback, which is smaller. But a project owner also gets back their own share of the fee, and a trader who also provides the pool's liquidity gets back most of the LP fee, so trading with themselves could be nearly free. Split the fee into three parts:

| Part | Examples | Counts as "leaves"? |
|---|---|---|
| Cashback | the trader's sIMD | no |
| Comes back to the owner or the trader | owner share, team treasury, liquidity the owner can withdraw, **LP fees** (the trader may be the liquidity provider) | no |
| Really leaves | burned tokens, liquidity locked forever, prizes paid to other people, fees to third parties | **yes** |

**Rule: "really leaves" ≥ cashback, at every rate and fee split the code allows.** Then every point an owner farms costs at least as much as it returns, plus price impact and gas.

- **PLEA passes:** fee 1.75% = 0.5% cashback + 0.5% owner + 0.25% locked liquidity + 0.25% burn + 0.25% season prizes. Leaves 0.75% ≥ 0.5%. An owner round trip of $10,000 costs $350 in fees, gets back $200 ($100 cashback, $100 owner share) and loses $150 for $100 of points.
- **Fails:** fee 1.25% = 1% cashback + 0.25% owner. Nothing leaves, so points are almost free. Such a project can still use imd/acc, unlisted.
- **Also fails:** 1% cashback with a 1% LP fee and nothing else leaving. A trader who provides 99% of the pool's liquidity gets 99% of that LP fee back: on $1,000 traded back and forth, $20 of cashback for about $0.20 of real cost.

### When points start

- Reviewed **before or at launch**: `fromBlock` is the deploy block, as there is no earlier history (PLEA's case).
- Listed **later**: `fromBlock` is the block it is listed. Nobody can trade first and have points backdated.

### Delisting

If a listed project breaks the rules (a rate outside 25 to 100, a fee split that fails the guard, credits to its own wallets), its entry gets a `toBlock`. Changing its rate inside the range and the guard is allowed. Points earned before it stay; later credits earn none. The entry is never deleted, so history stays readable.

### Every credit is checked too

The indexer compares each credit with the trade in the same transaction. A credit outside 25 to 100 bps of that trade, or with no trade on the project's pool in that transaction, earns no points.

### Who decides the file

The repository owner. Every change to the list is public in the git history: who was listed, when, and with which numbers.

## The ProjectRegistry, decided by an IMD panel

A small on-chain contract with **no owner** ([`src/ProjectRegistry.sol`](../src/ProjectRegistry.sol)), first deployed in Sepolia test run 2, with PLEA as the first applicant. **The Stacker is never redeployed:** it doesn't know about listings, so the site and the indexer read the registry's events instead of a file.

1. **Apply.** The project's owner (what its `owner()` returns), or the project contract itself, calls `applyListing(project, name, sourceUrl, rateBps, beneficiary)`; for a project without an owner, anyone can and pays the oracle fee (read live from the Intake: 0.5 IMD today). The project must be a contract; the rate 25 to 100.
2. **The panel answers** in a few minutes: true only if every rule on the checklist holds, including the fee guard and that the beneficiary belongs to the project's team. **Yes** lists the project from that block; **no** rejects it, and it can apply again.
3. **No answer** (the panel split or the question was refused): the application is cleared and can be sent again at once. Nothing is listed.
4. **Challenge.** Anyone can challenge a listed project, after a cooldown, by paying the oracle fee plus a bond. If the panel says it still meets the rules, it stays listed and **the bond goes to the project's beneficiary**; if not, it is delisted from that block, earlier points stay, and the challenger gets the bond back.
5. **Points** count a project's credits inside its listing periods only.

The full design, the checks every answer must pass, and the known limits are in [design.md](design.md#the-projectregistry).
