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
    nozzle_label: "N1", opened_at: iso(30), closed_at: iso(22), opening_meter: 1000, closing_meter: 1250,
    metered_liters: 250, sold_liters: 240, variance_liters: 10 },        // +10, red
  { id: "sh2", station_id: "s-adama", station_name: "Adama", staff_name: "Sara O'Brien",
    nozzle_label: "N2", opened_at: iso(20), closed_at: iso(12), opening_meter: 1250, closing_meter: 1400, closed_by_other: true,
    metered_liters: 150, sold_liters: 152, variance_liters: -2 },        // -2, green
  { id: "sh3", station_id: "s-adama", station_name: "Adama", staff_name: "Hana Tesfaye",
    nozzle_label: "N1", opened_at: iso(2), closed_at: null, opening_meter: 1400, closing_meter: null,
    metered_liters: null, sold_liters: 60, variance_liters: null },      // open
  // Left open overnight: no closing meter was ever read, so no variance can
  // exist. It must not be shown as merely "open" alongside a live shift.
  { id: "sh4", station_id: "s-adama", station_name: "Adama", staff_name: "Kebede Alemu",
    nozzle_label: "N3", opened_at: iso(50), closed_at: null, opening_meter: 900, closing_meter: null,
    metered_liters: null, sold_liters: 0, variance_liters: null, abandoned: true }
];

const ATT = [
  { id: "a1", station_id: "s-adama", station_name: "Adama", staff_name: "Abebe Kebede",
    check_in: iso(30), check_out: iso(22), hours: 8 },
  { id: "a2", station_id: "s-adama", station_name: "Adama", staff_name: "Hana Tesfaye",
    check_in: iso(2), check_out: null, hours: 2.03 },
  // A forgotten check-out. hours is null on purpose: nobody knows when they
  // went home, and the old code would have shown 50.00 and counting.
  { id: "a3", station_id: "s-adama", station_name: "Adama", staff_name: "Kebede Alemu",
    check_in: iso(50), check_out: null, hours: null, abandoned: true }
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
  close_shift: { success: true, message: "shift closed for them" },
  admin_add_note: { success: true, message: "note saved", id: "nt9" },
  admin_set_note: { success: true, message: "note updated" },
  admin_delete_note: { success: true, message: "note deleted" },
  admin_list_notes: [
    { id: "nt1", station_id: "s-adama", station_name: "Adama",
      body: "Pumps 1 and 2 are Benzil, the rest Diesel", pinned: true,
      author: "Owner", created_at: iso(48), updated_at: null },
    // No branch: applies everywhere, so it must not have to be written five times.
    { id: "nt2", station_id: null, station_name: "All branches",
      body: "Shift starts 6am and ends 6pm", pinned: false,
      author: "Owner", created_at: iso(24), updated_at: iso(2) }
  ],
  admin_resolve_correction: { success: true, message: "sale corrected" },
  admin_backup: {
    magpms_backup_version: 1, generated_at: "2026-07-31T21:00:00Z", timezone: "Africa/Addis_Ababa",
    counts: { stations: 2, staff: 4, tanks: 20, sales: 600, expenses: 0 },
    stations: ST, staff: [], tanks: [], fuel_prices: [], sales: [],
    credit_customers: [], expenses: [], shifts: [], attendance: [],
    deliveries: [], price_history: [], sale_corrections: []
  },
  report_staff: [
    { staff_id: "u2", staff_name: "Abebe Kebede", station_id: "s-adama", station_name: "Adama",
      sale_count: 12, liters: 480, sales_etb: 45600, cash_etb: 40600, credit_etb: 5000,
      voided_count: 2, days_active: 5, best_day: "2026-07-29" },
    // A name Excel would execute, and a person with nothing voided.
    { staff_id: "u3", staff_name: "=cmd|' /C calc'!A0", station_id: "s-evil",
      station_name: "=cmd|' /C calc'!A0",
      sale_count: 3, liters: 60, sales_etb: 7200, cash_etb: 7200, credit_etb: 0,
      voided_count: 0, days_active: 2, best_day: "2026-07-28" }
  ],
  admin_list_corrections: [
    { id: "c1", sale_id: "x1", station_id: "s-adama", station_name: "Adama",
      staff_name: "Abebe Kebede", reported_at: iso(2), reason: "typed 1000 instead of 100",
      claimed_liters: 100, status: "open", fuel_type: "Diesel",
      sale_liters: 1000, sale_total: 95000, payment_method: "cash", sale_at: iso(3),
      resolved_at: null, resolution_note: null, old_liters: null, new_liters: null }
  ],
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
await page.waitForFunction(() => document.querySelectorAll("#shiftBody tr").length === 4, null, { timeout: 5000 });
ok("four shift rows", (await page.locator("#shiftBody tr").count()) === 4);

/* A cashier who goes home without closing leaves a pump with no way out:
   only they could close it, so the variance was lost until the next day
   marked the shift abandoned. The manager can now take the reading. */
/* One button, not two: the abandoned shift has no closing meter to take, so
   close_shift would refuse it and a button that always fails is worse than
   none. */
ok("only a live open shift offers a Close",
   (await page.locator('[data-act="admin-close-shift"]').count()) === 1);

const variances = await page.locator("#shiftBody td.delta").allTextContents();
ok("positive variance is signed", variances[0].trim() === "+10.00", `got ${JSON.stringify(variances[0])}`);
ok("negative variance keeps its sign", variances[1].trim() === "-2.00", `got ${JSON.stringify(variances[1])}`);
ok("open shift shows no variance", variances[2].trim() === "—", `got ${JSON.stringify(variances[2])}`);

const upCls = await page.locator("#shiftBody tr:nth-child(1) td.delta").getAttribute("class");
const dnCls = await page.locator("#shiftBody tr:nth-child(2) td.delta").getAttribute("class");
ok("missing fuel flagged red", upCls.includes("up"), upCls);
ok("surplus flagged green", dnCls.includes("down"), dnCls);

const tags = await page.locator("#shiftBody .tag").allTextContents();
/* A shift left open overnight reads as "abandoned", not as "open" alongside
   somebody genuinely at the pump right now. The two mean opposite things:
   one needs no action, the other needs asking about. */
ok("shift status tags",
   tags.join(",") === "closed,closed,closed by manager,open,abandoned", tags.join(","));

const apos = await page.locator("#shiftBody tr:nth-child(2) td:nth-child(3)").textContent();
ok("apostrophe in a name survives", apos.includes("O'Brien"), apos);

/* A variance names a person, but a meter is the thing that can be wrong.
   Without the nozzle the column cannot point at a pump. */
const nozCol = await page.locator("#shiftBody tr:nth-child(1) td:nth-child(4)").textContent();
ok("the shift says which nozzle", nozCol.trim() === "N1", nozCol);

{ /* Closing asks for the reading rather than assuming one, and says whose
     pump it is - a manager standing at pump 3 should not have to guess
     which row they are about to close. */
  await page.click('[data-act="admin-close-shift"]');
  await page.waitForSelector("#uiModal.open", { timeout: 5000 });
  const dlg = await page.locator("#uiModal").textContent();
  ok("it names the pump", /N1/.test(dlg), dlg);
  ok("and who left it open", /Hana Tesfaye/.test(dlg), dlg);
  ok("and the opening reading", /1400/.test(dlg), dlg);
  await page.fill("#umInput", "1500");
  await page.click("#umOk");
  await page.waitForFunction(() =>
    JSON.stringify(window.__calls).includes("close_shift"), null, { timeout: 5000 });
  ok("the close is sent", true);
}

/* A variance from a meter the operator never read is worth less than one
   they did, so the row says which. */
ok("a manager-closed shift is labelled",
   (await page.locator("#shiftBody").textContent()).includes("closed by manager"));

ok("attendance rows", (await page.locator("#attBody tr").count()) === 3);
const attTags = await page.locator("#attBody .tag").allTextContents();
ok("on-duty tag for an open check-in",
   attTags.join(",") === "done,on duty,no check-out", attTags.join(","));

/* Hours must be blank on a forgotten check-out. The old code ran them to
   now(), so a Monday check-in with no check-out read as 50 hours and rising -
   a number that is not merely wrong but would be quoted in a wage argument. */
const attHours = await page.locator("#attBody tr:nth-child(3) td:nth-child(5)").textContent();
ok("no invented hours for a forgotten check-out", attHours.trim() === "—", attHours);

console.log("\n[3] reports");
await page.click('.mi[data-s="reports"]');
ok("CSV disabled before a run", await page.locator("#repCsv").isDisabled());
ok("30-day preset filled the pickers", (await page.locator("#repFrom").inputValue()).length === 10);

await page.click("#repBtn");
await page.waitForFunction(() => document.querySelectorAll("#repBody tr").length === 3, null, { timeout: 5000 });
ok("report rows", (await page.locator("#repBody tr").count()) === 3);

/* One row per day per branch with a column per fuel, rather than one row per
   fuel. Comparing diesel against petrol used to mean reading two rows that
   were not next to each other - on a phone, often not the same screen. */
const head = await page.locator("#repHead").textContent();
ok("a column per fuel sold", /Diesel L/.test(head) && /Benzil L/.test(head), head);
ok("fuel columns come from the data, not the markup",
   head.indexOf("Diesel") < head.indexOf("Sales"), head);
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
/* The CSV matches the table on screen, a column per fuel. A file laid out
   differently from what was checked is a file nobody trusts. */
ok("header row", csv.includes('"Day","Site","Benzil L","Diesel L","Sales","Total ETB"'),
   csv.split("\r\n")[0]);
ok("formula cell neutralised", csv.includes(`"'=cmd|' /C calc'!A0"`), csv.split("\r\n")[2]);
ok("no bare formula cell", !/,"=cmd/.test(csv));
ok("totals row", csv.includes('"Total","","60","780","23","81300.00"'), csv.split("\r\n").pop());
// 60 + 780 is the 840 litres the old flat layout reported, split by fuel.

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

console.log("\n[9] corrections reach the admin with both numbers");

/* Deciding without the sale's figure and the cashier's claim side by side
   means going and looking them up, which is how a report gets ignored. */
{
  await page.click('.mi[data-s="corrections"]');
  await page.waitForFunction(() =>
    document.querySelector("#corrList").textContent.includes("Abebe"), null, { timeout: 5000 });

  const t = await page.locator("#corrList").textContent();
  ok("the cashier is named", /Abebe Kebede/.test(t), t);
  ok("the sale as recorded is shown", /1,000 L/.test(t), t);
  ok("and what they say it should be", /100 L/.test(t), t);
  ok("in their own words", /typed 1000 instead of 100/.test(t), t);
  ok("with the branch", /Adama/.test(t), t);

  ok("an open report offers Fix", await page.locator('[data-act="corr-fix"]').count() === 1);
  ok("and Reject", await page.locator('[data-act="corr-reject"]').count() === 1);

  /* Rejecting must be a deliberate act - it leaves a wrong sale standing. */
  await page.click('[data-act="corr-reject"]');
  await page.waitForSelector("#uiModal.open", { timeout: 5000 });
  const dlg = await page.locator("#uiModal").textContent();
  ok("rejecting asks first", /Reject this report/i.test(dlg), dlg);
  ok("and says what will not happen",
     /nothing moves in the tank/i.test(dlg), dlg);
  await page.click("#umCancel");
  ok("cancelling sends nothing",
     !JSON.stringify(await page.evaluate(() => window.__calls)).includes("admin_resolve_correction"));

  /* The cashier's figure is offered, but the admin types the number that
     goes in - they are the one who can check it against the meter. */
  await page.click('[data-act="corr-fix"]');
  await page.waitForSelector("#uiModal.open", { timeout: 5000 });
  const fixDlg = await page.locator("#uiModal").textContent();
  ok("fixing shows the claimed figure", /100 litres/.test(fixDlg), fixDlg);
  await page.fill("#umInput", "100");
  await page.click("#umOk");
  await page.waitForFunction(() =>
    JSON.stringify(window.__calls).includes("admin_resolve_correction"), null, { timeout: 5000 });
  ok("fixing sends the correction", true);
}

{ // nothing waiting should read as nothing waiting, not as a failure
  await page.evaluate(() => { window.__override = { admin_list_corrections: [] }; });
  await page.click('#corrTabs [data-corr="fixed"]');
  await page.waitForFunction(() =>
    document.querySelector("#corrList").textContent.trim().length > 0, null, { timeout: 5000 });
  await page.click('#corrTabs [data-corr="open"]');
  await page.waitForFunction(() =>
    document.querySelector("#corrList").textContent.includes("Nothing waiting"), null, { timeout: 5000 });
  const empty = await page.locator("#corrList").textContent();
  ok("an empty queue is good news, and says so", /no staff have reported/i.test(empty), empty);
  await page.evaluate(() => { window.__override = {}; });
}

console.log("\n[10] the staff report");

{
  await page.click('.mi[data-s="reports"]');
  await page.click('#repQuick [data-range="7"]');
  await page.click("#stfBtn");
  await page.waitForFunction(() =>
    document.querySelector("#stfBody").textContent.includes("Abebe"), null, { timeout: 5000 });

  const t = await page.locator("#stfBody").textContent();
  ok("one row per person", (await page.locator("#stfBody tr").count()) === 2);
  ok("takings are shown", /45,600/.test(t), t);
  /* Cash and credit split the total rather than repeating it - the pair is
     what tells a manager how much should be in the drawer. */
  ok("cash and credit are separated", /40,600/.test(t) && /5,000/.test(t), t);
  ok("days active are counted", /\b5\b/.test(t), t);

  /* Voided sales are out of the money but counted, and flagged. Someone
     whose sales keep being voided is worth noticing. */
  ok("voids are called out", (await page.locator("#stfBody .tag.rejected").count()) === 1);

  ok("CSV becomes available", !(await page.locator("#stfCsv").isDisabled()));

  const dl = page.waitForEvent("download", { timeout: 8000 });
  await page.click("#stfCsv");
  const file = await dl;
  ok("the filename says who and when",
     /magpms-staff-.*-to-/.test(file.suggestedFilename()), file.suggestedFilename());

  const body = await (await import("node:fs/promises")).readFile(await file.path(), "utf8");
  ok("it has a header row", body.includes('"Person","Site","Sales"'), body.slice(0, 90));
  ok("and a total row", /\n"Total",/.test(body), body.slice(-160));
  /* A name beginning with = is a formula to Excel, not a name. */
  ok("a formula name is neutralised", body.includes("'=cmd"), body.slice(0, 400));
  ok("no bare formula cell", !/(^|,)=cmd/m.test(body), body.slice(0, 400));
}

{ // switching branch must not leave one branch's people under another's name
  await page.click('#rail [data-site="s-adama"]');
  await page.waitForFunction(() =>
    document.querySelector("#stfBody").textContent.includes("Choose a range"), null, { timeout: 5000 });
  ok("a stale staff report is cleared with the sales one",
     await page.locator("#stfCsv").isDisabled());
}

console.log("\n[11] backup");

{
  await page.click('.mi[data-s="backup"]');
  const dl = page.waitForEvent("download", { timeout: 8000 });
  await page.click("#bkBtn");
  const file = await dl;
  ok("the filename carries the date",
     /^magpms-backup-\d{4}-\d{2}-\d{2}\.json$/.test(file.suggestedFilename()),
     file.suggestedFilename());

  const raw = await readFile(await file.path(), "utf8");
  /* The CSV download prepends a BOM so Excel reads UTF-8. JSON.parse chokes
     on it, and this file exists to be read back by a machine. */
  ok("no BOM on a JSON file", !raw.startsWith("﻿"), JSON.stringify(raw.slice(0, 4)));

  let parsed = null;
  try { parsed = JSON.parse(raw); } catch { /* left null */ }
  ok("it parses", parsed !== null);
  ok("it says what version it is", parsed && parsed.magpms_backup_version === 1);
  ok("and when it was made", parsed && !!parsed.generated_at);
  ok("every table is present even when empty",
     parsed && ["stations","staff","tanks","fuel_prices","sales","credit_customers",
                "expenses","shifts","attendance","deliveries","price_history",
                "sale_corrections"].every(k => Array.isArray(parsed[k])));

  /* The counts are the point: a backup you cannot check is one you are
     trusting rather than one you have verified. */
  const chips = await page.locator("#bkCounts").textContent();
  ok("the counts are shown on screen", /sales: 600/.test(chips), chips);
  ok("and read as words, not column names", !/_/.test(chips), chips);
  ok("it says to keep a copy elsewhere",
     /off the phone/i.test(await page.locator("#bkMsg").textContent()));
}

{ // a refusal must read as a refusal, not as an empty backup
  await page.evaluate(() => { window.__override = { admin_backup: { error: "not authorised" } }; });
  await page.click('.mi[data-s="sales"]');
  await page.click('.mi[data-s="backup"]');
  await page.click("#bkBtn");
  await page.waitForFunction(() =>
    document.querySelector("#bkMsg").textContent.length > 0, null, { timeout: 5000 });
  const m = await page.locator("#bkMsg").textContent();
  ok("a refusal is explained", /only an admin/i.test(m), m);
  ok("and no counts are shown for it",
     (await page.locator("#bkCounts").textContent()).trim() === "");
  await page.evaluate(() => { window.__override = {}; });
}

console.log("\n[12] private notes");

/* The things worth remembering about a branch that are not a transaction.
   Admin only, and firmly so: a note may say "check Abebe's readings on pump
   4", which is reasonable to write and corrosive for Abebe to find. */
{
  await page.click('.mi[data-s="notes"]');
  await page.waitForFunction(() =>
    document.querySelector("#noteList").textContent.includes("Benzil"), null, { timeout: 5000 });

  const list = await page.locator("#noteList").textContent();
  ok("a branch note is shown", /Pumps 1 and 2 are Benzil/.test(list), list);
  ok("so is a business-wide one", /Shift starts 6am/.test(list), list);
  ok("each says which branch it is about", /Adama/.test(list) && /All branches/.test(list), list);
  ok("a pinned note is marked", (await page.locator("#noteList .tag").count()) >= 1);
  ok("an edited note says so", /edited/.test(list), list);

  ok("the page says staff never see them",
     /never see these/i.test(await page.locator("#sec-notes").textContent()));

  // An empty note is refused rather than saved as a blank row.
  await page.click("#noteBtn");
  await page.waitForFunction(() =>
    document.querySelector("#noteMsg").textContent.length > 0, null, { timeout: 5000 });
  ok("an empty note is refused",
     /write something/i.test(await page.locator("#noteMsg").textContent()));
  ok("and nothing was sent",
     !JSON.stringify(await page.evaluate(() => window.__calls)).includes("admin_add_note"));

  await page.fill("#noteBody", "Tank 3 gauge reads low");
  await page.click("#notePin");
  await page.waitForFunction(() =>
    JSON.stringify(window.__calls).includes("admin_add_note"), null, { timeout: 5000 });
  ok("a pinned note saves", true);
  ok("and the box is cleared for the next one",
     (await page.locator("#noteBody").inputValue()) === "");

  /* Deleting asks first: a note is the only thing here that cannot be
     reconstructed from anything else. */
  await page.click('[data-act="note-delete"]');
  await page.waitForSelector("#uiModal.open", { timeout: 5000 });
  const dlg = await page.locator("#uiModal").textContent();
  ok("deleting asks first", /Delete this note/i.test(dlg), dlg);
  ok("and says it cannot be recovered", /cannot be recovered/i.test(dlg), dlg);
  await page.click("#umCancel");
  ok("cancelling deletes nothing",
     !JSON.stringify(await page.evaluate(() => window.__calls)).includes("admin_delete_note"));
}

ok("still no uncaught page errors", pageErrors.length === 0, pageErrors.join("\n        "));

await browser.close();
server.kill();

console.log(failures ? `\n${failures} check(s) failed\n` : "\nAll checks passed\n");
process.exit(failures ? 1 : 0);
