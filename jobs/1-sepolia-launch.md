Build imd/acc on Sepolia (test run; contracts only, no token or pool): 0.5% trading cashback paid to traders as staked IMD (sIMD), funded from a project's existing fees. Owner: <OWNER_WALLET>.

DEPLOY (Sepolia, in this order):
1. TestIMD: ERC20 "Test IMD"/tIMD, 18 dec, no premint. faucet() mints 10,000 tIMD to the caller, once per 24h per address.
2. TestSIMD: a fork of POOL4 StakedIMD 0x9efa934d9fad4ae28c998a40195646b965a97247 (Ethereum). Asset TestIMD, owner $owner, name "Test Staked IMD"/tsIMD, logic unchanged; the owner keeps pause so integrators can test a failing vault.
3. Stacker(TestIMD, TestSIMD): immutable; constructor requires sIMD.asset()==IMD, approves the vault once. No owner, admin or fee.

STACKER:
- credit(trader, imdAmount) returns shares: pull imdAmount from msg.sender, call sIMD.deposit(imdAmount, trader), so the shares go straight to the trader. project = msg.sender. Trader 0 reverts; amount 0 returns 0, no event.
- On-chain totals (IMD): traderStacked, projectStacked, stackedBy[project][trader], totalStacked; plus shares per trader and project.
- event Stacked(address indexed project, address indexed trader, uint256 imd, uint256 shares).
- IMD path only; the ETH batch route is v2.

PAGE (static, IPFS label imd-acc-test, public RPCs):
- Your stack: IMD stacked, points, sIMD held and its IMD value now, split per project.
- Listed projects: a projects.json in the site ({address, name, fromBlock}; starts empty, PLEA's hook added later by a site update). Points and leaderboards count only Stacked events from listed projects at or after their fromBlock; others show as "direct, no points".
- Leaderboards: top stackers and top listed projects by IMD stacked, from chunked Stacked logs.
- Test tools: faucet, and "stack to myself" (approve + credit(self, x)), shown as direct.
- The three addresses with explorer links.

TESTS (Foundry): shares go only to the trader; totals and event match; many projects and traders; credit reverts cleanly when the vault is paused or allowance/balance is short (integrators use try/catch); faucet limit; fuzz; invariant: Stacker holds 0 IMD and 0 sIMD.

DELIVER: the three addresses in the README; the PLEA job reuses them.
