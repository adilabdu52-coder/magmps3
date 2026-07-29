/* MAGPMS shared UI: theme, navigation, toasts, modals, connection banner.
   Imported by every page; holds no station or fuel knowledge of its own. */

/* ---------- escaping ---------- */
/* Covers quotes as well as angle brackets, because values are interpolated
   into attributes (data-id, data-name) and not only into text. Note that
   escaping alone does not make an inline onclick safe - the HTML parser
   decodes entities before the handler body is compiled - so this file and the
   pages use delegated listeners with data-* attributes instead. */
export function esc(s) {
  return String(s === null || s === undefined ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

export const fmt = {
  int:   v => Math.round(Number(v) || 0).toLocaleString("en-US"),
  money: v => (Number(v) || 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 }),
  price: v => (Number(v) || 0).toFixed(2),
  time:  d => new Date(d).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" }),
  date:  d => new Date(d).toLocaleDateString("en-GB", { day: "2-digit", month: "short" }),
  stamp: d => new Date(d).toLocaleString("en-GB", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" })
};

/* ---------- auth errors, in words ---------- */
/* Supabase's auth errors arrive in wildly different shapes: sometimes a plain
   sentence, sometimes a status with an empty body - which stringifies to the
   literal string "{}" and was being printed to the screen as-is. A cashier
   locked out at 6am needs a sentence they can act on, not a fragment of JSON.

   Pass the original error object rather than re-wrapping it, so `status`
   survives; the rate limiter is the one case that is easier to recognise by
   code than by wording. */
export function authMessage(err, fallback = "Something went wrong. Please try again.") {
  const t = String((typeof err === "string" ? err : err?.message) ?? "").trim();
  const status = err?.status ?? err?.statusCode;

  if (status === 429 || /rate limit|too many requests/i.test(t))
    return "Too many emails have been sent from this project in the last hour. " +
           "Wait an hour, or ask the manager to set your password directly.";
  if (/invalid login credentials/i.test(t))
    return "Wrong email or password.";
  if (/signups? not allowed|signup is disabled/i.test(t))
    return "Sign-ups are closed. Ask the manager to create your account.";
  if (/email not confirmed/i.test(t))
    return "This account has not been confirmed yet. Ask the manager.";
  if (/(expired|invalid).*(token|link)|(token|link).*(expired|invalid)/i.test(t))
    return "That link has expired or was already used. Ask for a new one.";
  if (/failed to fetch|networkerror|load failed/i.test(t))
    return "No connection. Check the internet and try again.";

  // What an empty error body turns into once it has been through JSON and
  // String(). Neither means anything to the person reading it.
  if (!t || t === "{}" || t === "[object Object]" || t === "undefined") return fallback;
  return t;
}

/* ---------- theme ---------- */
const THEMES = ["dark", "light", "auto"];
const ICONS = { dark: "\u{1F319}", light: "☀️", auto: "\u{1F313}" };

function getTheme() {
  try { return localStorage.getItem("magpms_theme") || "dark"; } catch { return "dark"; }
}
function applyTheme(t) {
  document.documentElement.setAttribute("data-theme", t);
  const b = document.getElementById("themeBtn");
  if (b) { b.textContent = ICONS[t]; b.title = "Theme: " + t; }
}
function cycleTheme() {
  const next = THEMES[(THEMES.indexOf(getTheme()) + 1) % THEMES.length];
  try { localStorage.setItem("magpms_theme", next); } catch { /* private mode */ }
  applyTheme(next);
  toast("Theme: " + next);
}

/* ---------- navigation ---------- */
const isDesktop = () => window.innerWidth >= 900;

export function toggleMenu() {
  if (isDesktop()) return;                       // sidebar is permanent on desktop
  document.getElementById("sideMenu")?.classList.toggle("open");
  document.getElementById("menuOverlay")?.classList.toggle("show");
}

export function go(section, el) {
  document.querySelectorAll(".section").forEach(s => s.classList.remove("show"));
  document.getElementById("sec-" + section)?.classList.add("show");
  document.querySelectorAll(".mi").forEach(m =>
    m.classList.toggle("active", m.getAttribute("data-s") === section));
  document.querySelectorAll(".bn-item").forEach(b =>
    b.classList.toggle("active", b.getAttribute("data-s") === section));
  if (el?.classList.contains("mi")) toggleMenu();
  window.scrollTo(0, 0);
}

/* ---------- messages ---------- */
export function msg(id, text, type) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = text;
  el.className = "msg " + (type || "");
}

export function toast(text, kind) {
  let host = document.getElementById("toastHost");
  if (!host) {
    host = document.createElement("div");
    host.id = "toastHost";
    document.body.appendChild(host);
  }
  const t = document.createElement("div");
  t.className = "toast" + (kind ? " " + kind : "");
  t.textContent = text;
  host.appendChild(t);
  setTimeout(() => {
    t.style.transition = "opacity .3s";
    t.style.opacity = "0";
    setTimeout(() => t.remove(), 320);
  }, 2400);
}

/* ---------- connection banner ---------- */
function banner() {
  let b = document.getElementById("netBanner");
  if (!b) {
    b = document.createElement("div");
    b.id = "netBanner";
    b.textContent = "⚠ Connection problem — some data did not load. Check internet.";
    document.body.appendChild(b);
  }
  return b;
}
export const netFail = () => banner().classList.add("show");
export const netOk = () => document.getElementById("netBanner")?.classList.remove("show");

/* Reports a loader that failed instead of leaving its panel silently blank.
   Every catch in the pages calls this - an empty catch is how the old app
   turned a broken request into a panel that merely looked empty. */
export function loadFailed(where, err) {
  const detail = err?.name === "RpcError" ? `${err.fn}: ${err.message}` : err;
  console.error("[magpms] " + where + " failed:", detail);
  netFail();
}

/* ---------- dialogs ---------- */
let pendingResolve = null;

function ensureModal() {
  let bd = document.getElementById("uiModal");
  if (bd) return bd;
  bd = document.createElement("div");
  bd.id = "uiModal";
  bd.className = "modal-backdrop";
  bd.innerHTML =
    '<div class="modal"><h3 id="umTitle"></h3><p id="umText"></p>' +
    '<div class="field hidden" id="umField" style="margin-top:12px">' +
    '<label id="umLabel"></label>' +
    '<input id="umInput" type="number" step="0.01" min="0" inputmode="decimal"/></div>' +
    '<div class="m-actions"><button class="btn btn-ghost" id="umCancel">Cancel</button>' +
    '<button class="btn" id="umOk">OK</button></div></div>';
  document.body.appendChild(bd);
  bd.addEventListener("click", e => { if (e.target === bd) closeDialog(null); });
  return bd;
}

function closeDialog(value) {
  document.getElementById("uiModal")?.classList.remove("open");
  if (pendingResolve) { pendingResolve(value); pendingResolve = null; }
}

function openDialog(opts) {
  const bd = ensureModal();
  bd.querySelector("#umTitle").textContent = opts.title || "";
  bd.querySelector("#umText").textContent = opts.text || "";
  const field = bd.querySelector("#umField");
  const input = bd.querySelector("#umInput");
  if (opts.input) {
    field.classList.remove("hidden");
    bd.querySelector("#umLabel").textContent = opts.inputLabel || "";
    input.value = "";
  } else {
    field.classList.add("hidden");
  }

  // Replace the buttons so a previous dialog's listener cannot fire again.
  const ok = bd.querySelector("#umOk");
  ok.textContent = opts.okText || "OK";
  ok.className = "btn " + (opts.danger ? "btn-no" : "btn-gold");
  ok.style.width = "auto";
  const okFresh = ok.cloneNode(true);
  ok.replaceWith(okFresh);
  okFresh.addEventListener("click", () => closeDialog(opts.input ? input.value : true));

  const cancel = bd.querySelector("#umCancel");
  const cancelFresh = cancel.cloneNode(true);
  cancel.replaceWith(cancelFresh);
  cancelFresh.addEventListener("click", () => closeDialog(null));

  return new Promise(resolve => {
    pendingResolve = resolve;
    bd.classList.add("open");
    if (opts.input) setTimeout(() => input.focus(), 80);
  });
}

export const confirmDlg = (title, text, okText, danger) =>
  openDialog({ title, text, okText: okText || "Confirm", danger: danger !== false });

export const promptNumber = (title, text, label) =>
  openDialog({ title, text, input: true, inputLabel: label, okText: "Save", danger: false })
    .then(v => {
      if (v === null) return null;
      const n = parseFloat(v);
      return Number.isNaN(n) ? null : n;
    });

/* ---------- tanks ---------- */
/* Under 15% is a reorder, under 30% is low. A branch average can sit
   comfortably while one tank is already dry, so callers show both. */
export const tankPct = t => (Number(t.current_liters) / Number(t.capacity_liters)) * 100;
export const tankState = p => (p < 15 ? "crit" : p < 30 ? "warn" : "ok");
export const tankLabel = p => (p < 15 ? "REORDER" : p < 30 ? "LOW" : "OK");

export function tankRow(t) {
  const p = Math.max(0, Math.min(100, tankPct(t)));
  const st = tankState(p);
  return `<div class="row">
    <div class="l"><h4>${esc(t.tank_name)} · ${esc(t.fuel_type)}</h4>
      <p>${fmt.int(t.current_liters)} / ${fmt.int(t.capacity_liters)} L</p></div>
    <div class="lvl"><span class="bar"><i class="${st === "ok" ? "" : st}" style="width:${p.toFixed(1)}%"></i></span>
      <span class="pct">${p.toFixed(0)}%</span></div></div>`;
}

export const lowTanks = tanks => tanks.filter(t => tankPct(t) < 30).length;

export function stampUpdated(id) {
  const el = document.getElementById(id);
  if (el) el.textContent = "Updated " + new Date().toLocaleTimeString("en-GB");
}

/* ---------- clock ---------- */
function tick() {
  const n = new Date();
  const d = document.getElementById("clockDate");
  const t = document.getElementById("clockTime");
  if (d) d.textContent = n.toLocaleDateString("en-GB", { weekday: "long", day: "2-digit", month: "long", year: "numeric" });
  if (t) t.textContent = n.toLocaleTimeString("en-GB");
}

/* ---------- init ---------- */
applyTheme(getTheme());
document.addEventListener("DOMContentLoaded", () => {
  const tb = document.getElementById("themeBtn");
  if (tb) { tb.addEventListener("click", cycleTheme); applyTheme(getTheme()); }
  if (document.getElementById("sideMenu")) document.body.classList.add("has-sidebar");

  // Menu and section navigation are delegated, so markup carries no inline JS.
  document.addEventListener("click", e => {
    const nav = e.target.closest("[data-s]");
    if (nav) { go(nav.getAttribute("data-s"), nav); return; }
    if (e.target.closest("[data-menu-toggle]")) toggleMenu();
  });

  if (document.getElementById("clockTime")) { setInterval(tick, 1000); tick(); }
});
