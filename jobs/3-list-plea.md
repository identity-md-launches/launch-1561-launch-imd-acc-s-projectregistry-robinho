Continue imd/acc's test page: list PLEA as the first project that earns points. The contracts stay exactly as they are.

Live Sepolia addresses (unchanged): TestIMD 0x2b69099e59b05901faa1dd164fabf098bf831e82, TestSIMD 0xf9e2eec3b610ec6781f7438ac5fb4bc049d81cc1, Stacker 0x293c7134ab8f6bf1d8ff44ed806575f8f1baf477 (deploy block 11874601).

PAGES, WORDS AND LOOK: the same single page, its existing text and its existing design (DESIGN.md). Only the data below changes; no redesign or rewrite.

CHANGES:
1. site/public/projects.json and the committed dist/projects.json, both exactly:
[{"address":"0x3d4CcAc329010b8beA3b14498d9a45EAB00c68Cc","name":"PLEA","fromBlock":11885872}]
This is PLEA v10's hook, which calls Stacker.credit inside every PLEA/IMD swap; 11885872 is its deploy block, so points count from there and never before.
2. site/public/config.json and dist/config.json: put https://rpc.sepolia.ethpandaops.io first in rpcs, then https://sepolia.rpc.sentio.xyz, then https://ethereum-sepolia-rpc.publicnode.com. publicnode now answers eth_getLogs from block 11874601 with "pruned history unavailable"; the page fails over, but every fresh scan starts with a failed call.
3. README: projects.json now lists PLEA; mark "List PLEA" done in the after-launch checklist.

Nothing else changes: the Stacker, the 0.5% rate, the faucet and the points rule (1 point per IMD stacked by a listed project at or after its fromBlock) stay as they are. The older PleaHook 0x37337cd25f09a1cb77bba55d12358c9d00e2e8cc (an earlier PLEA test run) stays unlisted and keeps showing as unlisted, no points.

CHECK in a real browser against live Sepolia (read-only is enough; no transactions needed), at 360 px and 1280 px, light and dark:
- Listed projects shows PLEA, 0x3d4c…68cc, from block 11,885,872.
- Recent stacks marks the PLEA hook's Stacked events "listed"; the self-stacks of 100 and 1 tIMD stay "direct" and the two from 0x3733…e8cc "unlisted".
- As of block 11,889,300: top projects is PLEA with 0.1674 tIMD and 2 traders; top stackers are 0x0c85…7b7b (0.1029 stacked, 0.1 points) and 0x4b91…6821 (0.06 points, from PLEA only). Newer PLEA swaps only add to these.
- With a wallet set to 0x0c855176f4829a5814a285de218e29547fc47b7b: Your stack shows 0.1029 tIMD stacked, 0.1 points, the PLEA row "listed".
- No console errors, no horizontal scroll.
