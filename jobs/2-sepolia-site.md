Continue imd/acc: host its test page against the live Sepolia launch (#1129). Deploy no contracts and change none.

Live addresses (the launch's verified artifacts; use these, never placeholders):
- TestIMD 0x2b69099e59b05901faa1dd164fabf098bf831e82
- TestSIMD 0xf9e2eec3b610ec6781f7438ac5fb4bc049d81cc1
- Stacker 0x293c7134ab8f6bf1d8ff44ed806575f8f1baf477
- Stacker deploy block 11874601 (start of every log scan)

Start from the existing static page in site/ and keep its scope:
- site/config.json: fill addresses.testIMD/testSIMD/stacker and stackerDeployBlock 11874601. projects.json stays [] for now.
- Your stack: IMD stacked, points, sIMD held and its IMD value now (convertToAssets), split per project.
- Listed projects from projects.json {address, name, fromBlock}: points and leaderboards count only Stacked events from listed projects at or after their fromBlock; others show as "direct, no points".
- Leaderboards: top stackers and top listed projects, from chunked Stacked logs.
- Test tools: faucet (show the next allowed time from nextFaucetAt), and "stack to myself" (approve + credit(self, x)), shown as direct.
- The three addresses with Sepolia explorer links, and the vault's paused/open state.
- Wallet flow: connect, switch to Sepolia (11155111), per-button pending, success and error states; no horizontal scroll at 360px; light and dark.

Check it in a real browser against the live contracts: faucet, approve, credit, then the stack and leaderboard update. Update the README's address table with the three addresses. Host the page on IPFS with the label imd-acc-test.
