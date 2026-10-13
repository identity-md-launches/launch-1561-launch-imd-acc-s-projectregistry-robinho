// Menu by mouse and keyboard, aria-current in the open menu, back/forward, deep link + reload,
// docs select, theme toggle remembered, /llms.txt. Live Sepolia, no wallet.
import { launch, newPage } from "./lib.mjs";
const SITE = process.env.SITE || "https://imd-acc-sepolia-test-run-2.sites.imd.fun/";
const browser = await launch();
const out = [];
const ok = (cond, label) => out.push(`${cond ? "PASS" : "FAIL"} ${label}`);
const ready = (page) => page.getByText(/Data at block/).first().waitFor({ timeout: 120000 });

// 360px: the menu.
{
  const { page, log } = await newPage(browser, { width: 360, height: 780 });
  await page.goto(SITE + "#/", { waitUntil: "domcontentloaded" });
  await ready(page);
  const menu = page.locator(".menu-button");
  const nav = page.locator("#mobile-navigation");
  await menu.click();
  ok((await menu.getAttribute("aria-expanded")) === "true" && (await nav.isVisible()), "360: Menu opens on click");
  const navLinks = await nav.locator("a").allTextContents();
  ok(["Home", "Stack", "Projects", "Apply", "Leaderboard", "Docs"].every((t) => navLinks.some((l) => l.trim() === t)), `360: menu lists all pages (${navLinks.map((l) => l.trim()).join(", ")})`);
  ok((await nav.locator('[aria-current="page"]').allTextContents()).join() === "Home", "360: open menu marks Home as current");
  const barBefore = await page.locator(".topbar-inner").boundingBox();
  ok(barBefore.height < 60, `360: bar stays one row with menu open (${barBefore.height}px)`);
  ok((await page.evaluate(() => document.documentElement.scrollWidth)) === 360, "360: no horizontal scroll with menu open");
  await page.mouse.click(180, 700);
  await page.waitForTimeout(200);
  ok((await menu.getAttribute("aria-expanded")) === "false" && !(await nav.isVisible()), "360: outside click closes the menu");
  await menu.focus();
  await page.keyboard.press("Enter");
  await page.waitForTimeout(150);
  ok((await menu.getAttribute("aria-expanded")) === "true", "360: Enter on Menu opens it");
  await page.keyboard.press("Tab");
  const inMenu = await page.evaluate(() => !!document.activeElement.closest("#mobile-navigation"));
  await page.keyboard.press("Escape");
  await page.waitForTimeout(150);
  const focusBack = await page.evaluate(() => document.activeElement.classList.contains("menu-button"));
  ok((await menu.getAttribute("aria-expanded")) === "false" && focusBack, `360: Escape closes and returns focus to Menu (Tab reached menu link: ${inMenu})`);
  await menu.click();
  await nav.getByRole("link", { name: "Projects" }).click();
  await page.waitForTimeout(500);
  ok(page.url().endsWith("#/projects") && !(await nav.isVisible()), "360: a menu link navigates and closes the menu");
  await menu.click();
  ok((await nav.locator('[aria-current="page"]').allTextContents()).join() === "Projects", "360: open menu marks Projects as current");
  await page.keyboard.press("Escape");
  // Docs select below 860.
  await page.evaluate(() => (location.hash = "#/docs/what"));
  await page.waitForTimeout(500);
  const sel = page.locator("main select").first();
  const opts = await sel.locator("option").allTextContents();
  ok(opts.length === 7, `360: docs select has 7 sections (${opts.join(", ")})`);
  await sel.selectOption({ index: 4 });
  await page.waitForTimeout(500);
  ok(page.url().endsWith("#/docs/listing"), `360: choosing a section in the select navigates (${page.url().split("#")[1]})`);
  ok(log.errors.length === 0, `360: no console errors (${log.errors.length})`);
  await page.context().close();
}

// 1280px: history, deep link, reload, theme, prev/next.
{
  const { page, log } = await newPage(browser, { width: 1280, theme: "light" });
  await page.goto(SITE + "#/", { waitUntil: "domcontentloaded" });
  await ready(page);
  for (const name of ["Projects", "Leaderboard", "Docs"]) {
    await page.locator(".desktop-nav").getByRole("link", { name, exact: true }).click();
    await page.waitForTimeout(400);
  }
  ok(page.url().endsWith("#/docs/what"), `1280: Docs link opens #/docs/what (${page.url().split("#")[1]})`);
  ok((await page.locator(".desktop-nav [aria-current=page]").textContent()).trim() === "Docs", "1280: Docs marked current");
  const underline = await page.locator(".desktop-nav [aria-current=page]").evaluate((e) => getComputedStyle(e).textDecorationLine);
  ok(/underline/.test(underline), `1280: current page underlined (${underline})`);
  await page.goBack();
  await page.waitForTimeout(400);
  ok(page.url().endsWith("#/leaderboard") && (await page.title()) === "Leaderboard - imd/acc", `1280: Back goes to Leaderboard (${await page.title()})`);
  await page.goBack();
  await page.waitForTimeout(400);
  ok(page.url().endsWith("#/projects"), "1280: Back again goes to Projects");
  await page.goForward();
  await page.waitForTimeout(400);
  ok(page.url().endsWith("#/leaderboard"), "1280: Forward goes to Leaderboard");
  // Prev/next in docs.
  await page.goto(SITE + "#/docs/how", { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(800);
  const nextLink = page.locator("main a", { hasText: /Next/ }).first();
  await nextLink.click();
  await page.waitForTimeout(400);
  ok(page.url().endsWith("#/docs/addresses"), `1280: Next from How it works goes to Addresses (${page.url().split("#")[1]})`);
  const prev = page.locator("main a", { hasText: /Previous/ }).first();
  await prev.click();
  await page.waitForTimeout(400);
  ok(page.url().endsWith("#/docs/how"), "1280: Previous goes back to How it works");
  // Deep link + reload.
  await page.goto(SITE + "#/docs/points", { waitUntil: "domcontentloaded" });
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForTimeout(1500);
  ok((await page.locator("main h1").first().textContent()).trim() === "Points", "1280: deep link #/docs/points survives reload");
  await page.goto(SITE + "#/leaderboard", { waitUntil: "domcontentloaded" });
  await ready(page);
  ok((await page.locator("main h1").first().textContent()).trim() === "Leaderboard", "1280: deep link #/leaderboard loads data");
  await page.goto(SITE + "#/projects/0x3D1778bE5f9E55f0dF35ACAF64A13Efe2FE81488", { waitUntil: "domcontentloaded" });
  await ready(page);
  const projText = await page.locator("main").innerText();
  ok(/3d17|SelfCredit|not (been )?applied|no registry|never applied/i.test(projText), `1280: project deep link for an unregistered contract shows an explanation: "${projText.replace(/\s+/g, " ").slice(0, 160)}"`);
  // Theme toggle remembered.
  await page.locator(".theme-button").click();
  const t1 = await page.evaluate(() => document.documentElement.dataset.theme);
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForTimeout(500);
  const t2 = await page.evaluate(() => document.documentElement.dataset.theme);
  ok(t1 === "dark" && t2 === "dark", `1280: theme toggle to dark is remembered after reload (${t1}/${t2})`);
  // Footer link to Addresses.
  const footerHref = await page.locator("footer a[href*='addresses']").first().getAttribute("href").catch(() => null);
  ok(footerHref === "#/docs/addresses", `1280: footer links to Docs > Addresses (${footerHref})`);
  ok(log.errors.length === 0, `1280: no console errors (${log.errors.length}) ${log.errors.slice(0, 2)}`);
  await page.context().close();
}

// /llms.txt
{
  const r = await fetch(SITE + "llms.txt");
  const t = await r.text();
  ok(r.status === 200 && /0x0457276d7b036818b3eddc1a4a3fceda61e9314d/i.test(t) && /0x3a3bfcb65614292b0ec7c62f9e3a5dac003b920e/i.test(t), `/llms.txt served (${r.status}, ${r.headers.get("content-type")}, ${t.length} chars) with both addresses`);
}
await browser.close();
console.log(out.join("\n"));
