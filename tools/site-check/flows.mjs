// Wallet flows and form errors on a local Sepolia fork, at WIDTH (default 1280).
// Needs: fresh anvil fork with fixture A (TestSIMD address) listed by fork-answer.sh.
import { execFileSync } from "node:child_process";
import { launch, newPage, prepareAccount, anvil, ACCOUNT, axe } from "./lib.mjs";
const SITE = process.env.SITE || "https://imd-acc-sepolia-test-run-2.sites.imd.fun/";
const WIDTH = Number(process.env.WIDTH || 1280);
const SELF = "0x3D1778bE5f9E55f0dF35ACAF64A13Efe2FE81488"; // SelfCredit, live and on the fork
const FIX_A = "0xf9e2eec3b610ec6781f7438ac5fb4bc049d81cc1"; // fixture A: listed on the fork
const TIMD = "0x2b69099e59b05901faa1dd164fabf098bf831e82"; // fixture B: open question on the fork
const answer = (p, a) => execFileSync("./fork-answer.sh", [p, a]).toString().trim();
const out = [];
const ok = (cond, label) => { out.push(`${cond ? "PASS" : "FAIL"} ${label}`); console.log(out.at(-1)); };
await prepareAccount();
const browser = await launch();
const { page, log } = await newPage(browser, { width: WIDTH, height: 900, fork: true, wallet: true });
const ready = () => page.getByText(/Data at block/).first().waitFor({ timeout: 120000 });
const main = () => page.locator("main").innerText();
const go = async (h) => { await page.evaluate((x) => (location.hash = x), h); await page.waitForTimeout(600); };
const refresh = async () => { await page.getByRole("button", { name: "Refresh" }).first().click(); await page.waitForTimeout(2500); };
const clickWait = async (name, ms = 4000) => { await page.getByRole("button", { name, exact: true }).first().click(); await page.waitForTimeout(ms); };

await page.goto(SITE + "#/", { waitUntil: "domcontentloaded" });
await ready();
// Connect.
await page.locator(".connect-button").click();
await page.waitForTimeout(1500);
const short = ACCOUNT.slice(0, 6);
ok(new RegExp(short, "i").test(await page.locator("header").innerText()), "wallet connects; address in the top bar");

// Faucet, approve, credit.
await go("#/stack");
const before = await main();
await clickWait("Claim faucet", 5000);
ok(log.txs.some((t) => t.data === "0xde5f72fd"), "faucet transaction sent");
ok(/Next|next claim|available/i.test(await main()), "faucet shows the next allowed time");
await page.locator("#stack-amount").fill("5");
await clickWait("Approve IMD", 5000);
await clickWait("Stack to myself", 6000);
const credit = log.txs.find((t) => t.data === "0x8b1a8be6" || t.to?.toLowerCase() === "0x0457276d7b036818b3eddc1a4a3fceda61e9314d");
ok(!!credit, "credit (stack to myself) transaction sent to the Stacker");
const stackText = await main();
ok(/5\.0000/.test(stackText) && stackText !== before, "Your stack shows the 5 tIMD stacked");
ok(/direct|no points/i.test(stackText), "self-stack shown as direct, no points");
await go("#/leaderboard");
ok(new RegExp(short, "i").test(await main()), "Leaderboard lists the new stack");
await go("#/");
const home = await main();
ok(/your stack|stacked/i.test(home) && (await page.locator('main a[href="#/stack"]').count()) > 0, "Home shows a one-line stack summary linking to Stack");
const ratios = log.txs.map((t) => t.ratio).filter(Boolean);
ok(ratios.length >= 3 && ratios.every((r) => r >= 1.29 && r <= 1.31), `every tx sent with gas ≈ estimate × 1.3 (${ratios.join(", ")})`);

// Page changes don't rescan logs; Refresh does.
const scans0 = log.methods.eth_getLogs || 0;
for (const h of ["#/projects", "#/apply", "#/leaderboard", "#/stack", "#/docs/how", "#/"]) await go(h);
const scans1 = log.methods.eth_getLogs || 0;
await refresh();
const scans2 = log.methods.eth_getLogs || 0;
ok(scans1 === scans0 && scans2 > scans1, `changing page never rescans logs (${scans0}→${scans1}); Refresh does (→${scans2})`);

// Apply: field errors.
await go("#/apply");
const fieldErr = async (id, value, re, label) => {
  const input = page.locator(`#apply-${id}`);
  await input.fill(value);
  await input.blur();
  await page.waitForTimeout(id === "project" ? 2500 : 300);
  const err = (await page.locator(`#apply-${id}-error`).innerText()).trim();
  const inv = await input.getAttribute("aria-invalid");
  const desc = (await input.getAttribute("aria-describedby")) || "";
  const color = await page.locator(`#apply-${id}-error`).evaluate((e) => getComputedStyle(e).color);
  ok(re.test(err) && inv === "true" && desc.includes(`apply-${id}-error`), `Apply ${label}: "${err}" (aria-invalid ${inv}, colour ${color})`);
};
await fieldErr("project", "0x1234", /address/i, "not an address");
await fieldErr("project", "0x0000000000000000000000000000000000000001", /code|contract/i, "no contract code");
await fieldErr("name", "x".repeat(49), /48|long/i, "name too long");
await fieldErr("name", 'PLEA "v11"', /double quote/i, "double quote");
await fieldErr("name", "PLEA\\v11", /backslash/i, "backslash");
await fieldErr("name", "PLEA [v11]", /square bracket/i, "square bracket");
await fieldErr("name", "PLÉA", /non-ASCII/i, "non-ASCII");
await fieldErr("url", "http://example.com/plea", /https/i, "URL not https");
await fieldErr("url", "https://a.b", /12|short|characters/i, "URL too short");
await fieldErr("rate", "20", /25 to 100/i, "rate 20");
await fieldErr("rate", "101", /25 to 100/i, "rate 101");
await fieldErr("beneficiary", "0x0000000000000000000000000000000000000000", /zero/i, "beneficiary zero");
// Listed project and open question: say why the button is disabled.
await page.locator("#apply-project").fill(FIX_A);
await page.locator("#apply-project").blur();
await page.waitForTimeout(2500);
ok(/Already listed/i.test(await main()), "Apply with a listed project says \"Already listed\"");
await page.locator("#apply-project").fill(TIMD);
await page.locator("#apply-project").blur();
await page.waitForTimeout(2500);
ok(/already has an open question/i.test(await main()), "Apply with a project that has an open question says so");

// Apply for SelfCredit through the form.
await page.locator("#apply-project").fill(SELF);
await page.locator("#apply-name").fill("SelfCredit trial");
await page.locator("#apply-url").fill("https://github.com/khaed1/imd-acc/blob/main/test/trial/SelfCredit.sol");
await page.locator("#apply-rate").fill("50");
await page.locator("#apply-beneficiary").fill(ACCOUNT);
await page.locator("#apply-beneficiary").blur();
await page.waitForTimeout(3000);
const disabledLines = await page.locator("[id$='-apply-disabled']").allInnerTexts();
ok(disabledLines.some((l) => /fee|test IMD/i.test(l)), `disabled buttons say why: ${JSON.stringify(disabledLines.filter(Boolean))}`);
ok(/imd\/acc listing review/.test(await main()), "the exact panel question shows under the form");
await clickWait("Get 10 test IMD", 5000);
await clickWait("Approve fee", 5000);
await clickWait("Apply for listing", 7000);
ok(log.txs.length >= 6, `mint, approve and applyListing sent (${log.txs.length} txs so far)`);
const applyPage = await main();
ok(/SelfCredit trial/.test(applyPage) && /Open questions/i.test(applyPage), "the application appears under Open questions on Apply");

// Project page.
await go(`#/projects/${SELF}`);
await page.waitForTimeout(1500);
const proj = await main();
ok(/Applied/.test(proj) && /SelfCredit trial/.test(proj), "project page shows state Applied and its history");
ok(/historical/i.test(proj), "applied rate marked historical");
ok(/Expire/.test(proj), "open question with Expire on the project page");
ok(/age|ago|min|sec/i.test(proj), "open question shows its age");
// No answer: the failure callback clears it.
answer(SELF, "fail");
await refresh();
const cleared = await main();
ok(/AskCleared|cleared|no answer/i.test(cleared), "after a failure callback the history shows the question cleared");

// Challenge form on listed fixture A: cooldown first.
await go(`#/projects/${FIX_A}`);
await page.waitForTimeout(1500);
let fa = await main();
ok(/Listed/.test(fa) && /Challenge listing/.test(fa), "listed project page has the Challenge form");
ok(/cooldown is not over\. Challenge opens/i.test(fa), "Challenge says the cooldown is not over, and when it opens");
ok(/5\.5|5\.5000/.test(fa), "Challenge shows fee + bond (5.5 test IMD)");
const reason = page.locator("#challenge-reason");
await reason.fill("Credits outside trades \\ test");
await reason.blur();
await page.waitForTimeout(300);
ok(/backslash/i.test(await page.locator("#challenge-reason-error").innerText()) && (await reason.getAttribute("aria-invalid")) === "true", "Challenge reason error names the backslash");
await reason.fill("");
await reason.blur();
await page.waitForTimeout(300);
ok(/Reason/i.test(await page.locator("#challenge-reason-error").innerText()), `Challenge empty reason: "${(await page.locator("#challenge-reason-error").innerText()).trim()}"`);
// Pass the cooldown, then challenge through the form.
await anvil("evm_increaseTime", [3700]);
await anvil("evm_mine", []);
await refresh();
await reason.fill("Trial challenge: please check the fee guard and the rate range.");
await reason.blur();
await page.waitForTimeout(500);
await clickWait("Get 10 test IMD", 5000).catch(() => {});
await clickWait("Approve fee + bond", 5000);
await clickWait("Challenge listing", 7000);
fa = await main();
ok(/Challenge/.test(fa) && /Expire/.test(fa), "challenge opened; open question shown on the project page");
const chTx = log.txs.at(-1);
ok(chTx && chTx.to?.toLowerCase() === "0x3a3bfcb65614292b0ec7c62f9e3a5dac003b920e", `challenge tx went to the registry (selector ${chTx?.data})`);
answer(FIX_A, "yes");
await refresh();
fa = await main();
ok(/Defended/.test(fa), "after a yes the history shows Defended (bond to beneficiary)");
await go("#/projects");
const filters = await page.locator(".filters button").allInnerTexts();
ok(["All", "Listed", "Applied", "Delisted"].every((f) => filters.some((x) => x.includes(f))), `Projects filters: ${filters.join(", ")}`);
await page.locator(".filters button", { hasText: "Listed" }).first().click();
await page.waitForTimeout(400);
const listedRows = await page.locator(".project-table tbody tr").count();
ok(listedRows >= 1, `Listed filter shows ${listedRows} row(s)`);
const ax = await axe(page);
ok(ax.length === 0, `axe on populated Projects: ${ax.length} violations ${ax.slice(0, 2)}`);
ok(log.errors.length === 0, `no console errors in the whole run (${log.errors.length}) ${log.errors.slice(0, 3).join(" | ")}`);
await browser.close();
console.log("\nSUMMARY", out.filter((l) => l.startsWith("PASS")).length, "pass,", out.filter((l) => l.startsWith("FAIL")).length, "fail");
console.log("txs", JSON.stringify(log.txs.map((t) => [t.data, t.ratio])));
