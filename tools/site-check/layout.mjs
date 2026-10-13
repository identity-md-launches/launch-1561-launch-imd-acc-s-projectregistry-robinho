// Every route at 360/768/1280 in both themes: overflow, one-row top bar, menu vs desktop nav,
// aria-current, title, h1 focus, text sizes, data block, axe, console errors.
// FORK=1 routes RPCs to the local fork (populated registry); otherwise live Sepolia.
import { writeFileSync } from "node:fs";
import { launch, newPage, measure, axe } from "./lib.mjs";
const SITE = process.env.SITE || "https://imd-acc-sepolia-test-run-2.sites.imd.fun/";
const FORK = !!process.env.FORK;
const WIDTHS = (process.env.WIDTHS || "360,768,1280").split(",").map(Number);
const THEMES = (process.env.THEMES || "light,dark").split(",");
const PROJECTS = (process.env.PROJECTS || "0x3D1778bE5f9E55f0dF35ACAF64A13Efe2FE81488").split(",");
const docs = ["what", "how", "addresses", "integrate", "listing", "points", "agents"];
const routes = ["#/stack", "#/projects", ...PROJECTS.map((p) => `#/projects/${p}`), "#/apply", "#/leaderboard", "#/", "#/docs", ...docs.map((d) => `#/docs/${d}`), "#/nope"];
const chainPages = new Set(["#/", "#/stack", "#/projects", "#/apply", "#/leaderboard", ...PROJECTS.map((p) => `#/projects/${p}`)]);
const browser = await launch();
const results = [];
const problems = [];
for (const width of WIDTHS)
  for (const theme of THEMES) {
    const { page, log } = await newPage(browser, { width, height: 860, theme, fork: FORK });
    await page.goto(SITE + "#/", { waitUntil: "domcontentloaded" });
    await page.getByText(/Data at block/).first().waitFor({ timeout: 120000 });
    await page.evaluate(() => document.fonts.ready);
    const logsAfterLoad = log.methods.eth_getLogs || 0;
    for (const route of routes) {
      await page.evaluate(() => window.scrollTo(0, 400));
      await page.evaluate((r) => (location.hash = r), route);
      await page.waitForTimeout(700);
      const m = await measure(page);
      const extra = await page.evaluate(() => {
        const q = (s) => document.querySelector(s);
        const vis = (el) => !!el && getComputedStyle(el).display !== "none" && el.getBoundingClientRect().width > 0;
        const inner = q(".topbar-inner");
        const kids = inner ? [...inner.children].filter(vis).map((e) => Math.round(e.getBoundingClientRect().top)) : [];
        const current = [...document.querySelectorAll('[aria-current="page"]')].filter(vis).map((e) => e.textContent.trim());
        const docSelect = [...document.querySelectorAll("select")].find((s) => vis(s) && /what|how|addresses/i.test(s.innerHTML));
        const docSide = [...document.querySelectorAll("nav")].find((n) => vis(n) && /For agents/.test(n.textContent) && !n.closest("header"));
        const text = document.body.innerText;
        return {
          innerHeight: inner ? Math.round(inner.getBoundingClientRect().height) : null,
          rowTops: kids,
          menuVisible: vis(q(".menu-button")),
          desktopNavVisible: vis(q(".desktop-nav")),
          current,
          scrollY: Math.round(scrollY),
          active: document.activeElement?.tagName,
          docSelect: !!docSelect,
          docSide: !!docSide,
          prevNext: /Previous|Next/.test([...document.querySelectorAll("main a")].map((a) => a.textContent).join(" ")),
          notFound: /not found/i.test(text),
          homeLink: !!document.querySelector('main a[href="#/"]'),
        };
      });
      const issues = [];
      if (m.scrollWidth > m.vw) issues.push(`horizontal scroll ${m.scrollWidth}>${m.vw}`);
      if (m.overflow.length) issues.push(`overflow ${m.overflow.join(",")}`);
      if (extra.rowTops.length && Math.max(...extra.rowTops) - Math.min(...extra.rowTops) > 8) issues.push(`top bar not one row ${extra.rowTops}`);
      if (extra.innerHeight > 64) issues.push(`top bar ${extra.innerHeight}px tall`);
      if (width < 860 && (!extra.menuVisible || extra.desktopNavVisible)) issues.push("menu/desktop nav wrong below 860");
      if (width >= 860 && (extra.menuVisible || !extra.desktopNavVisible)) issues.push("menu/desktop nav wrong from 860");
      if (m.tooSmall.length) issues.push(`text under 11px ${m.tooSmall}`);
      const max = Math.max(...m.fontSizes);
      if (max > (width < 480 ? 18 : 22)) issues.push(`largest text ${max}px`);
      if (extra.scrollY !== 0) issues.push(`not scrolled to top (${extra.scrollY})`);
      if (extra.active !== "H1") issues.push(`focus on ${extra.active}, not h1`);
      if (!/ - imd\/acc$/.test(m.title) && route !== "#/") issues.push(`title "${m.title}"`);
      if (chainPages.has(route) && !m.dataBlock) issues.push("no data block shown");
      if (route.startsWith("#/docs")) {
        if (width < 860 && !extra.docSelect) issues.push("no docs select below 860");
        if (width >= 860 && !extra.docSide) issues.push("no docs side nav from 860");
        if (!extra.prevNext) issues.push("no previous/next links");
      }
      if (route === "#/nope" && (!extra.notFound || !extra.homeLink)) issues.push("not-found page missing");
      if (route !== "#/nope" && !extra.current.length) issues.push("no aria-current");
      const ax = await axe(page);
      if (ax.length) issues.push(...ax.map((a) => `axe ${a}`));
      results.push({ width, theme, route, title: m.title, h1: m.h1, current: extra.current, sizes: m.fontSizes, bar: extra.innerHeight, block: m.dataBlock, issues });
      if (issues.length) problems.push(`${width} ${theme} ${route}: ${issues.join("; ")}`);
    }
    const logsAfterNav = log.methods.eth_getLogs || 0;
    results.push({ width, theme, logScans: { afterLoad: logsAfterLoad, afterAllRoutes: logsAfterNav }, errors: log.errors, failed: log.failed.slice(0, 5) });
    if (log.errors.length) problems.push(`${width} ${theme}: console errors ${JSON.stringify(log.errors.slice(0, 3))}`);
    await page.context().close();
  }
await browser.close();
writeFileSync(`layout-${FORK ? "fork" : "live"}.json`, JSON.stringify(results, null, 1));
console.log(`${results.length} entries, ${problems.length} with problems`);
for (const p of problems) console.log("PROBLEM", p);
for (const r of results.filter((r) => r.logScans)) console.log(r.width, r.theme, "getLogs calls (FORK only):", JSON.stringify(r.logScans), "errors", r.errors.length);
