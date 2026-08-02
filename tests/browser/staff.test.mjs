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

const NOZZLES = [
  { id: "n1", station_id: "s-adama", station_name: "Adama", label: "N1",
    fuel_type: "Diesel", active: true, open_shift_id: null, open_by: null },
  { id: "n2", station_id: "s-adama", station_name: "Adama", label: "N2",
    fuel_type: "Benzil", active: true, open_shift_id: null, open_by: null },
  // Somebody else is on this one, so it must not be offered.
  { id: "n3", station_id: "s-adama", station_name: "Adama", label: "N3",
    fuel_type: "Diesel", active: true, open_shift_id: "sh9", open_by: "Chaltu" }
];

const OPEN_SHIFTS = [
  { id: "sh1", nozzle_id: "n1", nozzle_label: "N1", fuel_type: "Diesel",
    opened_at: new Date().toISOString(), opening_meter: 1000, sold_liters: 40 },
  { id: "sh2", nozzle_id: "n2", nozzle_label: "N2", fuel_type: "Benzil",
    opened_at: new Date().toISOString(), opening_meter: 5000, sold_liters: 10 }
];

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

  /* A cashier is asked "have you got diesel?" all day. The stock behind them
     belongs on the screen they land on, not one tab away. */
  await page.waitForFunction(() =>
    document.querySelector("#myStock").textContent !== "0", null, { timeout: 5000 });
  ok("the branch's fuel stock is on My Day",
     (await page.locator("#myStock").textContent()) === "30,000",
     await page.locator("#myStock").textContent());
  ok("and says how many tanks that is across",
     /1 tank\b/.test(await page.locator("#myStockSub").textContent()),
     await page.locator("#myStockSub").textContent());
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
  // Stock is the whole branch, low tank or not: 4,000 + 40,000.
  ok("stock counts every tank, not just the healthy ones",
     (await page.locator("#myStock").textContent()) === "44,000",
     await page.locator("#myStock").textContent());
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
  ok("and stock reads zero rather than a stale number",
     (await page.locator("#myStock").textContent()) === "0");
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

console.log("\n[6] reporting a sale that was rung up wrong");

/* A cashier cannot edit a saved sale, and should not be able to. Before this
   there was nowhere for a mistyped one to go: they told someone verbally, or
   it surfaced a week later as a variance nobody could explain. */
{
  const { page, ctx } = await open({
    me: WITH_BRANCH,
    data: {
      my_sales_today: SALES,
      list_tanks: TANKS,
      report_sale_mistake: { success: true, message: "reported - the manager will review it" },
      my_corrections: [
        { id: "c1", sale_id: "s1", reported_at: new Date().toISOString(),
          reason: "typed 1000 instead of 100", claimed_liters: 100, status: "fixed",
          fuel_type: "Diesel", old_liters: 1000, new_liters: 100 }
      ]
    }
  });
  await page.click('.mi[data-s="report"]');

  await page.waitForFunction(() =>
    document.querySelectorAll("#rpSale option").length > 1, null, { timeout: 5000 });
  const opts = await page.locator("#rpSale option").allTextContents();
  ok("only live sales can be reported", opts.length === 3, JSON.stringify(opts));
  ok("and they are identifiable", /Diesel/.test(opts.join(" ")), JSON.stringify(opts));
  ok("a voided sale is not offered", !/999/.test(opts.join(" ")), JSON.stringify(opts));

  // A reason is required: a report with no reason is a shrug.
  await page.click("#rpBtn");
  await page.waitForFunction(() =>
    document.querySelector("#rpMsg").textContent.length > 0, null, { timeout: 5000 });
  ok("a reason is required",
     /what went wrong/i.test(await page.locator("#rpMsg").textContent()),
     await page.locator("#rpMsg").textContent());
  ok("and nothing was sent",
     !JSON.stringify(await page.evaluate(() => window.__calls)).includes("report_sale_mistake"));

  /* Litres may be left blank. Someone who knows a sale is wrong but not by
     how much must still be able to say so. */
  await page.fill("#rpReason", "typed 1000 instead of 100");
  await page.click("#rpBtn");
  await page.waitForFunction(() =>
    JSON.stringify(window.__calls).includes("report_sale_mistake"), null, { timeout: 5000 });
  ok("a report with no litres still goes", true);
  ok("and it is confirmed on screen",
     /manager/i.test(await page.locator("#rpMsg").textContent()),
     await page.locator("#rpMsg").textContent());
  ok("the reason box is cleared for the next one",
     (await page.locator("#rpReason").inputValue()) === "");

  const mine = await page.locator("#rpList").textContent();
  ok("the cashier can see what happened to it", /fixed/i.test(mine), mine);
  ok("including the numbers that changed", /1,000/.test(mine) && /100/.test(mine), mine);

  await ctx.close();
}

console.log("\n[7] a shift belongs to a nozzle");

/* A meter belongs to a pump, not to a person. Working two pumps means two
   shifts, and selling is limited to the pumps you have opened - which is what
   keeps a meter reading matching what came out of it. */
{
  const { page, ctx } = await open({
    me: WITH_BRANCH,
    data: {
      list_nozzles: NOZZLES,
      my_open_shifts: OPEN_SHIFTS,
      get_prices: [{ fuel_type: "Diesel", price_per_liter: 100 },
                   { fuel_type: "Benzil", price_per_liter: 90 }],
      my_sales_today: [], list_tanks: TANKS
    }
  });
  await page.click('.mi[data-s="shift"]');
  await page.waitForFunction(() =>
    document.querySelectorAll("#openNozzle option").length > 0, null, { timeout: 5000 });

  const free = await page.locator("#openNozzle option").allTextContents();
  ok("only free nozzles can be opened", free.length === 2, JSON.stringify(free));
  ok("one already in use is not offered", !free.join(" ").includes("N3"), JSON.stringify(free));
  ok("the fuel is shown with the nozzle", /Diesel/.test(free.join(" ")), JSON.stringify(free));

  /* Each open shift needs its own closing box. One shared box would ask which
     pump the reading belongs to, and a wrong answer is a false variance on
     two pumps at once. */
  ok("every open shift has its own close button",
     (await page.locator("[data-close-shift]").count()) === 2);
  const list = await page.locator("#openShiftList").textContent();
  ok("each names its nozzle", /N1/.test(list) && /N2/.test(list), list);
  ok("and what it has sold", /40/.test(list) && /10/.test(list), list);

  const banner = await page.locator("#shiftBanner2").textContent();
  ok("the banner counts the pumps", /2 pumps open/.test(banner), banner);

  // Selling is limited to the pumps this person has open.
  await page.click('.mi[data-s="pos"]');
  const sellable = await page.locator("#sNozzle option").allTextContents();
  ok("only opened nozzles can be sold from", sellable.length === 2, JSON.stringify(sellable));
  ok("N3 is not sellable either", !sellable.join(" ").includes("N3"), JSON.stringify(sellable));

  /* The price follows the nozzle. A separate fuel picker could disagree with
     the pump, and then stock and takings drift apart. */
  await page.selectOption("#sNozzle", "n2");
  await page.fill("#sLiters", "10");
  await page.waitForFunction(() =>
    document.querySelector("#liveTotal").textContent.includes("90"), null, { timeout: 5000 });
  const total = await page.locator("#liveTotal").textContent();
  ok("the price comes from the nozzle's fuel", /900/.test(total) && /90\.00\/L/.test(total), total);

  await ctx.close();
}

{ // with nothing open, selling is impossible and says why
  const { page, ctx } = await open({
    me: WITH_BRANCH,
    data: { list_nozzles: NOZZLES, my_open_shifts: [], my_sales_today: [], list_tanks: TANKS }
  });
  await page.click('.mi[data-s="pos"]');
  await page.waitForFunction(() =>
    document.getElementById("saleBtn").disabled === true, null, { timeout: 5000 });
  ok("the sale button is disabled with no shift", await page.locator("#saleBtn").isDisabled());
  ok("and the nozzle box says what to do",
     (await page.locator("#sNozzle").textContent()).includes("Open a shift first"));
  await ctx.close();
}

ok("no uncaught page errors anywhere", errors.length === 0, errors.join("\n        "));

await browser.close();
server.kill();
console.log(failures ? `\n${failures} check(s) failed\n` : "\nAll checks passed\n");
process.exit(failures ? 1 : 0);
