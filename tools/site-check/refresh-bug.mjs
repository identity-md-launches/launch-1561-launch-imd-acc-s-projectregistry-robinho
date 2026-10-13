// Reviewer's medium finding: does a data refresh briefly remove the panel question and the
// no-code error on Apply? Fork, 360px, a new block before each Refresh.
import { launch, newPage, anvil } from "./lib.mjs";
const SITE = process.env.SITE || "https://imd-acc-sepolia-test-run-2.sites.imd.fun/";
const browser = await launch();
const { page, log } = await newPage(browser, { width: 360, height: 844, fork: true });
await page.goto(SITE + "#/apply", { waitUntil: "domcontentloaded" });
await page.getByText(/Data at block/).first().waitFor({ timeout: 120000 });
// Case 1: valid form, unlisted contract with code (the Stacker), question visible.
await page.locator("#apply-project").fill("0x0457276d7b036818b3eddc1a4a3fceda61e9314d");
await page.locator("#apply-name").fill("Review");
await page.locator("#apply-url").fill("https://example.test/source");
await page.locator("#apply-beneficiary").fill("0x3a3bfcb65614292b0ec7c62f9e3a5dac003b920e");
await page.locator("#apply-beneficiary").blur();
await page.waitForFunction(() => !!document.querySelector("#apply-panel pre"), undefined, { timeout: 30000 });
await page.locator("#apply-panel pre").scrollIntoViewIfNeeded();
await page.evaluate(() => {
  window.__gone = 0; window.__heights = [document.documentElement.scrollHeight]; window.__scrolls = [scrollY];
  new MutationObserver(() => {
    if (!document.querySelector("#apply-panel pre")) window.__gone++;
    window.__heights.push(document.documentElement.scrollHeight); window.__scrolls.push(Math.round(scrollY));
  }).observe(document.body, { childList: true, subtree: true });
});
for (let i = 0; i < 3; i++) {
  await anvil("evm_mine", []);
  await page.getByRole("button", { name: "Refresh" }).first().click();
  await page.waitForTimeout(3000);
}
const c1 = await page.evaluate(() => ({ gone: window.__gone, minH: Math.min(...window.__heights), maxH: Math.max(...window.__heights), scrolls: [...new Set(window.__scrolls)].slice(0, 6) }));
console.log("question removed during refresh (mutations without it):", c1.gone, "height range", c1.minH, "-", c1.maxH, "scrollY seen", c1.scrolls);
// Case 2: no-code address error during refresh.
await page.locator("#apply-project").fill("0x0000000000000000000000000000000000000001");
await page.locator("#apply-project").blur();
await page.waitForFunction(() => /code/i.test(document.querySelector("#apply-project-error")?.textContent || ""), undefined, { timeout: 30000 });
await page.evaluate(() => {
  window.__lost = 0;
  new MutationObserver(() => {
    const e = document.querySelector("#apply-project-error");
    const i = document.querySelector("#apply-project");
    if (!e?.textContent.trim() || i?.getAttribute("aria-invalid") !== "true") window.__lost++;
  }).observe(document.body, { childList: true, subtree: true, attributes: true, characterData: true });
});
for (let i = 0; i < 3; i++) {
  await anvil("evm_mine", []);
  await page.getByRole("button", { name: "Refresh" }).first().click();
  await page.waitForTimeout(3000);
}
console.log("no-code error lost during refresh (mutations):", await page.evaluate(() => window.__lost));
console.log("errors", log.errors.length);
await browser.close();
