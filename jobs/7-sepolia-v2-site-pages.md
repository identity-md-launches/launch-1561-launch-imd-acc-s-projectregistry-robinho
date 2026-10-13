Rework the imd/acc Sepolia test run 2 site from one long app page into separate pages, keep everything that works, and fix two issues. Deploy no contracts and change none. Keep the look, text sizes, colours, theme handling, wallet flow, RPC order, gas x1.3, compact rules and Impeccable rules of the current site exactly.

PAGES (hash routes, so deep links and reloads work on IPFS):
- #/ Home: what imd/acc is in two sentences; three short facts (cashback 0.25%-1% of each trade paid as staked IMD, no owner, 1 point per IMD from a listed project); if connected, a one-line summary of your stack linking to Stack; vault open or paused with its totals; the last 5 stacks; links to Apply and Docs. No hero numbers.
- #/stack Your stack: the current Your stack section in full (cashback received, points, tsIMD held, worth now, earned on top, per-project table), then Test tools (faucet, stack to myself).
- #/projects Projects: the table with All, Listed, Applied and Delisted filters; each row opens its page.
- #/projects/<address> one project: state, applied rate (marked historical), beneficiary, listing periods, its registry history as a dated list (Applied, Listed, Rejected, Challenged, Defended, Delisted, AskCleared, BeneficiarySet), IMD stacked and traders inside its periods, its open question with age and Expire, and the Challenge form here when it is listed (fee + bond, challengeForBeneficiary with the shown beneficiary).
- #/apply Apply: the three-step form and the panel question, then Open questions and Recent outcomes for all projects.
- #/leaderboard Leaderboard: top stackers, top projects, last 10 stacks.
- #/docs Docs: one route per section (#/docs/what, /how, /addresses, /integrate, /listing, /points, /agents). The contents list becomes the docs navigation (beside the text from 860px, a select at the top below) with previous and next links at the bottom. /llms.txt stays as it is.
- Contracts move to Docs > Addresses; the footer links there.
- Any unknown route shows a short not-found message with a link home.

NAVIGATION: top bar with imd/acc, Home, Stack, Projects, Apply, Leaderboard, Docs, the theme toggle and Connect. From 860px it is one row. Below 860px the page links collapse into a Menu button that opens a list under the bar (Escape and outside click close it, focus returns to the button); the bar itself stays one row with no wrap and no horizontal scroll, as now. Mark the current page (underline and aria-current). On a page change: scroll to top, set the document title ("Projects - imd/acc"), move focus to the page h1. Back and forward work.

STATE: one wallet connection and one data cache shared by all pages. Changing page never rescans logs; the Refresh button and each confirmed transaction do. Show the block the data is from on every page that shows chain data.

FIX 1, form errors: on Apply and Challenge, each field shows its own error under it once left or when a send is tried, in the alarm colour with aria-invalid and aria-describedby: not an address; not a contract (no code); name or reason too long or short; a character not allowed (say which: double quote, backslash or square bracket, or non-ASCII); URL not https:// or wrong length; rate outside 25-100; beneficiary zero; listed project's cooldown not over (show when). When a button is disabled, the line under it says why, including "This project already has an open question" and "Already listed".

FIX 2, layout: no tall empty gaps beside shorter boxes. Pages are one column; use two columns only where both sides have about the same height, otherwise stack them.

CHECK before delivering, in a real browser against live Sepolia (transactions on a local fork are fine), every route at 360, 768 and 1280px in both themes: no console errors, no horizontal scroll, the top bar one row; the menu opens and closes by mouse and keyboard; deep links and reload work; faucet, approve, credit, then Stack and Leaderboard update; get test IMD, open an application and see it on Apply and on the project's page; each form error appears with its reason. Run npx impeccable detect on the source and the running page and fix every finding; if it can't run, check the rules by hand and say so.
