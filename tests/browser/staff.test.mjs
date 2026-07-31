/* The cashier's page, against a stubbed Supabase client.
   This page had no coverage until twenty people were about to use it. */
import { chromium } from "playwright";
import { spawn } from "node:child_process";

const ROOT = process.env.MAGPMS_ROOT ?? new URL("../..", import.meta.url).pathname;
const PORT = 8733;
const BASE = `http://127.0.0.1:${PORT}`;

let failures = 0;
const ok = (name, cond, extra = "") => {
  if (cond) console.log(`  ok    ${name}`);
  else { failures++; console.log(`  FAIL  ${name}${extra ? "\n        " + extra : ""}`); }
};

const TANKS = [
  { id: 1, station_id: "s-adama", tank_name: "Tank 1", fuel_type: "Benzil",
    current_liters: 30000, capacity_liters: 50000 }
];

const STUB = `
export function createClient() {
  const cfg = window.__STUB__ = window.__STUB__ || {};
  window.__calls = [];
  return {
    auth: {
      getSession: async () => ({ data: { session: { access_token: "stub" } } }),
      signOut: async () => ({}),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } })
    },
    rpc: async (fn) => {
      window.__calls.push(fn);
      if (fn === "me") return { data: [cfg.me], error: null };
      const d = cfg.data && fn in cfg.data ? cfg.data[fn] : [];
      return { data: d, error: null };
    }
  };
}`;

const server = spawn("python3", ["-m", "http.server", String(PORT), "--bind", "127.0.0.1"],
  { cwd: ROOT, stdio: "ignore" });
await new Promise(r => setTimeout(r, 700));

const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
const errors = [];

async function open(stub) {
  const ctx = await browser.newContext();
  await ctx.route(/esm\.sh/, r =>
    r.fulfill({ status: 200, contentType: "application/javascript", body: STUB }));
  const page = await ctx.newPage();
  page.on("pageerror", e => errors.push(String(e)));
  await page.addInitScript(s => { window.__STUB__ = s; }, stub);
  await page.goto(`${BASE}/staff.html`);
  await page.waitForSelector("#app", { state: "visible", timeout: 8000 });
  return { page, ctx };
}

const WITH_BRANCH = {
  id: "u2", full_name: "Abebe Kebede", role: "operator", status: "approved",
  station_id: "s-adama", station_name: "Adama"
};
const NO_BRANCH = {
  id: "u5", full_name: "Hana Tesfaye", role: "operator", status: "approved",
  station_id: null, station_name: null
};

console.log("\n[1] a cashier with a branch");

{
  const { page, ctx } = await open({ me: WITH_BRANCH, data: { list_tanks: TANKS } });
  ok("the branch is named", (await page.locator("#stationLine").textContent()).includes("Adama"));
  ok("no warning banner", await page.locator("#noBranchBanner").isHidden());
  await page.waitForFunction(() =>
    document.querySelector("#tankList").textContent.includes("Tank 1"), null, { timeout: 5000 });
  ok("tanks are listed", (await page.locator("#tankList").textContent()).includes("Tank 1"));
  await ctx.close();
}

console.log("\n[2] a cashier approved without a branch");

/* This is what happens when someone is approved before being given a branch.
   Every panel comes back empty, because list_tanks and get_prices filter on
   current_station(). The page used to answer "No tanks configured", which
   sends them to look at the tanks - the tanks are fine. */
{
  const { page, ctx } = await open({ me: NO_BRANCH, data: { list_tanks: [] } });

  ok("the banner is shown", await page.locator("#noBranchBanner").isVisible());
  const banner = await page.locator("#noBranchBanner").textContent();
  ok("it says sales are not possible", /cannot record sales/i.test(banner), banner);
  ok("and who can fix it", /manager/i.test(banner), banner);

  ok("the header says so too", (await page.locator("#stationLine").textContent()).includes("No branch"));

  await page.waitForFunction(() =>
    document.querySelector("#tankList").textContent.trim().length > 0, null, { timeout: 5000 });
  const tanks = await page.locator("#tankList").textContent();
  ok("the tank panel blames the branch, not the tanks",
     /no branch assigned/i.test(tanks), tanks);
  ok("it does not claim the tanks are missing",
     !/no tanks configured/i.test(tanks), tanks);

  await ctx.close();
}

console.log("\n[3] a branch whose tanks really are missing");

/* Same empty result, different cause, different sentence. */
{
  const { page, ctx } = await open({ me: WITH_BRANCH, data: { list_tanks: [] } });
  await page.waitForFunction(() =>
    document.querySelector("#tankList").textContent.trim().length > 0, null, { timeout: 5000 });
  const tanks = await page.locator("#tankList").textContent();
  ok("this one does blame the tanks", /no tanks configured/i.test(tanks), tanks);
  ok("and not the branch", !/no branch assigned/i.test(tanks), tanks);
  ok("no warning banner for someone who has a branch",
     await page.locator("#noBranchBanner").isHidden());
  await ctx.close();
}

ok("no uncaught page errors anywhere", errors.length === 0, errors.join("\n        "));

await browser.close();
server.kill();
console.log(failures ? `\n${failures} check(s) failed\n` : "\nAll checks passed\n");
process.exit(failures ? 1 : 0);
