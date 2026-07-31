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

const SALES = [
  { id: "s1", fuel_type: "Diesel", liters: 30, total_etb: 3000, payment_method: "cash",
    voided: false, created_at: new Date().toISOString() },
  { id: "s2", fuel_type: "Diesel", liters: 20, total_etb: 2000, payment_method: "credit",
    voided: false, created_at: new Date().toISOString() },
  { id: "s3", fuel_type: "Benzil", liters: 10, total_etb: 900, payment_method: "cash",
    voided: false, created_at: new Date().toISOString() },
  // Voided sales must not count towards anything.
  { id: "s4", fuel_type: "Benzil", liters: 999, total_etb: 99900, payment_method: "cash",
    voided: true, created_at: new Date().toISOString() }
];

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

console.log("\n[2] My Day answers the questions a cashier actually has");

{
  const { page, ctx } = await open({
    me: WITH_BRANCH,
    data: {
      list_tanks: TANKS,
      my_sales_today: SALES,
      get_prices: [{ fuel_type: "Diesel", price_per_liter: 100 },
                   { fuel_type: "Benzil", price_per_liter: 90 }],
      my_open_shift: [],
      my_attendance_status: []
    }
  });
  await page.waitForFunction(() =>
    document.querySelector("#myCount").textContent !== "0", null, { timeout: 5000 });

  ok("takings exclude voided sales",
     (await page.locator("#mySales").textContent()) === "5,900",
     await page.locator("#mySales").textContent());
  ok("litres exclude them too",
     (await page.locator("#myLiters").textContent()) === "60",
     await page.locator("#myLiters").textContent());
  ok("the sale count is the live ones",
     (await page.locator("#myCount").textContent()) === "3",
     await page.locator("#myCount").textContent());
  /* Credit is what is not in the drawer at the end of the day. */
  ok("credit is broken out on its own",
     (await page.locator("#myCredit").textContent()) === "2,000",
     await page.locator("#myCredit").textContent());

  const fuel = await page.locator("#myByFuel").textContent();
  ok("fuels are broken down", /Diesel/.test(fuel) && /Benzil/.test(fuel), fuel);
  ok("busiest fuel first",
     (await page.locator("#myByFuel tr").first().textContent()).includes("Diesel"));
  ok("voided litres are not in the breakdown", !/999/.test(fuel), fuel);

  ok("prices are on My Day too",
     (await page.locator("#dashPrices").textContent()).includes("Diesel"));

  /* Without an open shift nothing can be sold, so it belongs on the first
     screen rather than two taps away. */
  ok("the shift warning is on My Day",
     (await page.locator("#dashShift").textContent()).includes("No open shift"));
  ok("so is attendance",
     (await page.locator("#dashAtt").textContent()).includes("Not checked in"));

  // 30000/50000 is 60%, so nothing is low and the card stays away.
  ok("no low-tank card when nothing is low", await page.locator("#lowTankCard").isHidden());
  await ctx.close();
}

console.log("\n[3] a tank running low is surfaced before a customer finds it");

{
  const { page, ctx } = await open({
    me: WITH_BRANCH,
    data: {
      list_tanks: [
        { id: 1, station_id: "s-adama", tank_name: "Tank 1", fuel_type: "Benzil",
          current_liters: 4000, capacity_liters: 50000 },   // 8% - reorder
        { id: 2, station_id: "s-adama", tank_name: "Tank 2", fuel_type: "Diesel",
          current_liters: 40000, capacity_liters: 50000 }   // 80% - fine
      ],
      my_sales_today: []
    }
  });
  await page.waitForFunction(() =>
    !document.getElementById("lowTankCard").classList.contains("hidden"), null, { timeout: 5000 });
  const low = await page.locator("#lowTankList").textContent();
  ok("the low tank is named", /Tank 1/.test(low), low);
  ok("the healthy one is not", !/Tank 2/.test(low), low);
  await ctx.close();
}

console.log("\n[4] a cashier approved without a branch");

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

console.log("\n[5] a branch whose tanks really are missing");

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
