/* Exercises the new admin sections against a stubbed Supabase client.
   esm.sh and every RPC are intercepted, so this runs with no network. */
import { chromium } from "playwright";
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";

const ROOT = process.env.MAGPMS_ROOT ?? new URL("../..", import.meta.url).pathname;
const PORT = 8731;
const BASE = `http://127.0.0.1:${PORT}`;

let failures = 0;
const ok = (name, cond, extra = "") => {
  if (cond) console.log(`  ok    ${name}`);
  else { failures++; console.log(`  FAIL  ${name}${extra ? "\n        " + extra : ""}`); }
};

/* ---------- canned data ---------- */
const ST = [
  { id: "s-adama", name: "Adama", town: "Adama, East Shewa" },
  // A branch name that Excel would execute, to prove the CSV guard fires.
  { id: "s-evil", name: "=cmd|' /C calc'!A0", town: "Test" }
];

const iso = h => new Date(Date.now() - h * 3600e3).toISOString();

const SHIFTS = [
  { id: "sh1", station_id: "s-adama", station_name: "Adama", staff_name: "Abebe Kebede",
    opened_at: iso(30), closed_at: iso(22), opening_meter: 1000, closing_meter: 1250,
    metered_liters: 250, sold_liters: 240, variance_liters: 10 },        // +10, red
  { id: "sh2", station_id: "s-adama", station_name: "Adama", staff_name: "Sara O'Brien",
    opened_at: iso(20), closed_at: iso(12), opening_meter: 1250, closing_meter: 1400,
    metered_liters: 150, sold_liters: 152, variance_liters: -2 },        // -2, green
  { id: "sh3", station_id: "s-adama", station_name: "Adama", staff_name: "Hana Tesfaye",
    opened_at: iso(2), closed_at: null, opening_meter: 1400, closing_meter: null,
    metered_liters: null, sold_liters: 60, variance_liters: null }       // open
];

const ATT = [
  { id: "a1", station_id: "s-adama", station_name: "Adama", staff_name: "Abebe Kebede",
    check_in: iso(30), check_out: iso(22), hours: 8 },
  { id: "a2", station_id: "s-adama", station_name: "Adama", staff_name: "Hana Tesfaye",
    check_in: iso(2), check_out: null, hours: 2.03 }
];

const REPORT = [
  { day: "2026-07-27", station_id: "s-adama", station_name: "Adama", fuel_type: "Diesel",
    sale_count: 12, liters: 480, sales_etb: 45600 },
  { day: "2026-07-27", station_id: "s-evil", station_name: "=cmd|' /C calc'!A0", fuel_type: "Benzil",
    sale_count: 3, liters: 60, sales_etb: 7200 },
  { day: "2026-07-26", station_id: "s-adama", station_name: "Adama", fuel_type: "Diesel",
    sale_count: 8, liters: 300, sales_etb: 28500 }
];

const DATA = {
  me: [{ id: "u1", full_name: "Owner", email: "o@x.com", role: "admin",
         status: "approved", station_id: null, station_name: null }],
  list_stations: ST,
  admin_dashboard: ST.map((s, i) => ({
    station_id: s.id, station_name: s.name, town: s.town,
    sales_today_etb: 1000 * (i + 1), liters_today: 100, stock_liters: 40000 * (i + 1),
    capacity_liters: 200000, credit_etb: 500, on_duty: 2, low_tanks: i
  })),
  list_tanks: [{ id: 1, station_id: "s-adama", tank_name: "Tank 1", fuel_type: "Benzil",
                 current_liters: 12000, capacity_liters: 50000 }],
  list_sales: [{ id: "x1", station_id: "s-adama", station_name: "Adama", staff_name: "Abebe",
                 fuel_type: "Diesel", liters: 20, total_etb: 1900,
                 payment_method: "cash", voided: false, created_at: iso(1) }],
  get_prices: [{ fuel_type: "Benzil", price_per_liter: 91.5 },
               { fuel_type: "Diesel", price_per_liter: 95.0 }],
  price_history: [],
  admin_list_staff: [
    // An admin with no branch is correct, not stranded - that is how the
    // central admin sees all five - so this row must NOT raise the warning.
    { id: "u1", full_name: "Owner", email: "o@x.com", phone: null,
      role: "admin", status: "approved", station_id: null },
    // Approved, no branch: can sign in, cannot sell.
    { id: "u2", full_name: "Abebe Kebede", email: "a@x.com", phone: null,
      role: "operator", status: "approved", station_id: null },
    // Approved with a branch: working, and must not be named.
    { id: "u3", full_name: "Sara O'Brien", email: "s@x.com", phone: null,
      role: "operator", status: "approved", station_id: "s-adama" },
    // Waiting. Approving this one is what fires the warning toast.
    { id: "u4", full_name: "Hana Tesfaye", email: "h@x.com", phone: null,
      role: "operator", status: "pending", station_id: null }
  ],
  admin_set_staff_status: { success: true, message: "staff approved" },
  admin_set_price: { success: true, message: "price updated" },
  list_deliveries: [],
  list_credit_customers: [],
  list_expenses: [],
  list_shifts: SHIFTS,
  list_attendance: ATT,
  report_sales: REPORT
};

/* A stand-in for the esm.sh module, with a per-page call log. */
const STUB = `
export function createClient() {
  const DATA = ${JSON.stringify(DATA)};
  window.__calls = [];
  window.__fail = window.__fail || {};
  return {
    auth: {
      getSession: async () => ({ data: { session: { access_token: "stub" } } }),
      signOut: async () => ({}),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } })
    },
    rpc: async (fn, params) => {
      window.__calls.push(fn);
      if (window.__fail[fn]) return { data: null, error: { message: "stubbed failure", code: "X" } };
      // __override lets one test change what a single RPC returns, which is
      // how a branch with tanks but no prices can be represented at all.
      const ov = window.__override || {};
      const d = fn in ov ? ov[fn] : (DATA[fn] === undefined ? [] : DATA[fn]);
      return { data: d, error: null };
    }
  };
}`;

/* ---------- harness ---------- */
const server = spawn("python3", ["-m", "http.server", String(PORT), "--bind", "127.0.0.1"],
  { cwd: ROOT, stdio: "ignore" });
await new Promise(r => setTimeout(r, 700));

const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
const ctx = await browser.newContext({ acceptDownloads: true });
await ctx.route(/esm\.sh/, route =>
  route.fulfill({ status: 200, contentType: "application/javascript", body: STUB }));

const page = await ctx.newPage();
const pageErrors = [];
page.on("pageerror", e => pageErrors.push(String(e)));

await page.goto(`${BASE}/admin.html`);
await page.waitForSelector("#app", { state: "visible", timeout: 8000 });

console.log("\n[1] page boots and loads only what it shows");
ok("no uncaught page errors", pageErrors.length === 0, pageErrors.join("\n        "));
ok("dashboard rendered", (await page.locator("#stockBody tr").count()) === 2);

let calls = await page.evaluate(() => window.__calls);
ok("admin_dashboard called on boot", calls.includes("admin_dashboard"));
ok("list_shifts NOT called before opening the section", !calls.includes("list_shifts"));
ok("report_sales NOT called before running a report", !calls.includes("report_sales"));
ok("list_expenses NOT called before opening the section", !calls.includes("list_expenses"));

console.log("\n[2] shifts & attendance");
await page.click('.mi[data-s="shifts"]');
await page.waitForFunction(() => document.querySelectorAll("#shiftBody tr").length === 3, null, { timeout: 5000 });
ok("three shift rows", (await page.locator("#shiftBody tr").count()) === 3);

const variances = await page.locator("#shiftBody td.delta").allTextContents();
ok("positive variance is signed", variances[0].trim() === "+10.00", `got ${JSON.stringify(variances[0])}`);
ok("negative variance keeps its sign", variances[1].trim() === "-2.00", `got ${JSON.stringify(variances[1])}`);
ok("open shift shows no variance", variances[2].trim() === "—", `got ${JSON.stringify(variances[2])}`);

const upCls = await page.locator("#shiftBody tr:nth-child(1) td.delta").getAttribute("class");
const dnCls = await page.locator("#shiftBody tr:nth-child(2) td.delta").getAttribute("class");
ok("missing fuel flagged red", upCls.includes("up"), upCls);
ok("surplus flagged green", dnCls.includes("down"), dnCls);

const tags = await page.locator("#shiftBody .tag").allTextContents();
ok("shift status tags", tags.join(",") === "closed,closed,open", tags.join(","));

const apos = await page.locator("#shiftBody tr:nth-child(2) td:nth-child(3)").textContent();
ok("apostrophe in a name survives", apos.includes("O'Brien"), apos);

ok("attendance rows", (await page.locator("#attBody tr").count()) === 2);
const attTags = await page.locator("#attBody .tag").allTextContents();
ok("on-duty tag for an open check-in", attTags.join(",") === "done,on duty", attTags.join(","));

console.log("\n[3] reports");
await page.click('.mi[data-s="reports"]');
ok("CSV disabled before a run", await page.locator("#repCsv").isDisabled());
ok("30-day preset filled the pickers", (await page.locator("#repFrom").inputValue()).length === 10);

await page.click("#repBtn");
await page.waitForFunction(() => document.querySelectorAll("#repBody tr").length === 3, null, { timeout: 5000 });
ok("report rows", (await page.locator("#repBody tr").count()) === 3);
ok("CSV enabled after a run", await page.locator("#repCsv").isEnabled());

const stats = await page.locator("#repStats .val").allTextContents();
ok("total ETB summed", stats[0] === "81,300", stats[0]);              // 45600+7200+28500
ok("litres summed", stats[1] === "840", stats[1]);                    // 480+60+300
ok("transactions summed", stats[2] === "23", stats[2]);               // 12+3+8
const days = await page.locator("#repStats .unit").nth(2).textContent();
ok("counts trading days, not calendar days", days.includes("2 trading days"), days);

console.log("\n[4] CSV export");
const [dl] = await Promise.all([page.waitForEvent("download"), page.click("#repCsv")]);
const csv = await readFile(await dl.path(), "utf8");
ok("filename carries branch and range", /^magpms-sales-all-sites-\d{4}-\d{2}-\d{2}-to-\d{4}-\d{2}-\d{2}\.csv$/.test(dl.suggestedFilename()), dl.suggestedFilename());
ok("BOM present for Excel", csv.charCodeAt(0) === 0xfeff);
ok("header row", csv.includes('"Day","Site","Fuel","Sales","Litres","ETB"'));
ok("formula cell neutralised", csv.includes(`"'=cmd|' /C calc'!A0"`), csv.split("\r\n")[2]);
ok("no bare formula cell", !/,"=cmd/.test(csv));
ok("totals row", csv.includes('"Total","","","23","840","81300.00"'), csv.split("\r\n").pop());

console.log("\n[5] switching branch clears a stale report");
await page.click('#rail [data-site="s-adama"]');
await page.waitForFunction(() =>
  document.querySelector("#repBody").textContent.includes("Choose a range"), null, { timeout: 5000 });
ok("report cleared for the new branch", await page.locator("#repCsv").isDisabled());
ok("section heading follows the rail", (await page.locator("#repSub").textContent()).includes("Adama"));

console.log("\n[6] a failed load says so instead of sitting on Loading...");
await page.evaluate(() => { window.__fail.list_expenses = true; });
await page.click('.mi[data-s="expenses"]');
await page.waitForFunction(() =>
  document.querySelector("#expBody").textContent.includes("Could not load"), null, { timeout: 5000 });
const expText = await page.locator("#expBody").textContent();
ok("expenses panel reports the failure", expText.includes("Could not load expenses"), expText.trim());

await page.evaluate(() => { window.__fail.list_expenses = false; });
await page.click('.mi[data-s="sales"]');
await page.click('.mi[data-s="expenses"]');
await page.waitForFunction(() =>
  !document.querySelector("#expBody").textContent.includes("Could not load"), null, { timeout: 5000 });
ok("a failed section retries on the next visit", true);

console.log("\n[7] approved staff with no branch are not left invisible");

/* Approving someone moves them off the Pending tab and takes the branch
   dropdown with them. That is how an operator ends up approved, unable to
   sell, and convinced the app is broken - it happened on the live system.
   The warning is counted across everyone, not across the current tab. */
await page.click('#rail [data-site="all"]');
await page.click('.mi[data-s="staff"]');
await page.waitForFunction(() =>
  !document.getElementById("staffNoBranch").classList.contains("hidden"), null, { timeout: 5000 });

const warn = await page.locator("#staffNoBranch").textContent();
ok("the warning is shown", await page.locator("#staffNoBranch").isVisible());
ok("it names the person who is stuck", warn.includes("Abebe Kebede"), warn);
ok("it says what they cannot do", /cannot record a sale/i.test(warn), warn);
ok("an admin with no branch is not counted", !warn.includes("Owner"), warn);
ok("someone who has a branch is not counted", !warn.includes("Sara"), warn);

/* The Pending tab is where the approving happens, so the warning has to
   survive being on it - that is the tab where the stranded person is not. */
ok("and it survives the tab that hides them",
   await page.locator("#staffNoBranch").isVisible());

// Approving someone with no branch warns at the moment it happens.
await page.click('#staffTabs [data-filter="pending"]');
await page.waitForFunction(() =>
  document.querySelector("#staffList").textContent.includes("Hana"), null, { timeout: 5000 });
await page.click('[data-act="staff-status"][data-id="u4"][data-status="approved"]');
await page.waitForFunction(() =>
  document.querySelectorAll("#toastHost .toast").length > 0, null, { timeout: 5000 });
const toastText = await page.locator("#toastHost .toast").last().textContent();
ok("approving without a branch warns immediately", /give Hana Tesfaye a branch/i.test(toastText), toastText);
ok("and says why it matters", /cannot sell/i.test(toastText), toastText);

console.log("\n[8] a branch can be given its first price");

/* The form used to be built from get_prices alone, so it could only EDIT a
   price that already existed. A branch with none rendered no inputs and read
   "No fuels configured" - there was no way to set a first price, and that
   branch could never trade. Found on the live system with a cashier assigned
   to a branch that had never been priced. */
await page.click('#rail [data-site="s-adama"]');

{ // tanks, but nothing priced yet
  await page.evaluate(() => {
    window.__override = {
      get_prices: [],
      list_tanks: [
        { id: 1, station_id: "s-adama", tank_name: "T1", fuel_type: "Diesel",
          current_liters: 100, capacity_liters: 1000 },
        { id: 2, station_id: "s-adama", tank_name: "T2", fuel_type: "Benzil",
          current_liters: 100, capacity_liters: 1000 }
      ]
    };
  });
  await page.click('.mi[data-s="sales"]');
  await page.click('.mi[data-s="prices"]');
  await page.waitForFunction(() =>
    document.querySelectorAll('#priceFields input[data-fuel]').length > 0, null, { timeout: 5000 });

  const fuels = await page.locator('#priceFields input[data-fuel]').evaluateAll(
    els => els.map(e => e.getAttribute("data-fuel")));
  ok("a box appears for every fuel the branch stocks",
     fuels.length === 2 && fuels.includes("Diesel") && fuels.includes("Benzil"), JSON.stringify(fuels));

  const values = await page.locator('#priceFields input[data-fuel]').evaluateAll(
    els => els.map(e => e.value));
  ok("and they start empty, waiting to be filled", values.every(v => v === ""), JSON.stringify(values));
  ok("the label says it has no price yet",
     (await page.locator("#priceFields").textContent()).includes("not priced yet"));
  ok("the save button is available", !(await page.locator("#priceBtn").isDisabled()));

  // One filled, one left blank: save what is known, do not block on the rest.
  await page.fill('#priceFields input[data-fuel="Diesel"]', "95");
  await page.click("#priceBtn");
  await page.waitForFunction(() =>
    document.querySelector("#priceMsg").textContent.length > 0, null, { timeout: 5000 });
  const m = await page.locator("#priceMsg").textContent();
  ok("a partly filled form still saves", /updated/i.test(m), m);

  // Nothing filled at all is a different answer.
  await page.evaluate(() => {
    document.querySelectorAll('#priceFields input[data-fuel]').forEach(i => { i.value = ""; });
  });
  await page.click("#priceBtn");
  await page.waitForFunction(() =>
    document.querySelector("#priceMsg").textContent.includes("at least one"), null, { timeout: 5000 });
  ok("an empty form asks for at least one price",
     (await page.locator("#priceMsg").textContent()).includes("at least one"));
}

{ // no tanks either: the branch needs tanks, not prices
  await page.evaluate(() => { window.__override = { get_prices: [], list_tanks: [] }; });
  // Sections only refetch when the branch changes, so switch branch rather
  // than tab - switching tabs alone would re-show the cached render.
  await page.click('#rail [data-site="s-evil"]');
  await page.waitForFunction(() =>
    document.querySelector("#priceFields").textContent.includes("no tanks"), null, { timeout: 5000 });
  const t = await page.locator("#priceFields").textContent();
  ok("a branch with no tanks says so", /no tanks yet/i.test(t), t);
  ok("and does not blame the fuels", !/No fuels configured/i.test(t), t);
}

await page.evaluate(() => { window.__override = {}; });

ok("still no uncaught page errors", pageErrors.length === 0, pageErrors.join("\n        "));

await browser.close();
server.kill();

console.log(failures ? `\n${failures} check(s) failed\n` : "\nAll checks passed\n");
process.exit(failures ? 1 : 0);
