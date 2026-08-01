/* Static checks for the MAGPMS pages.
 *
 * There is no build step and most of the JavaScript lives inside <script>
 * blocks in the HTML, so a plain `node --check` over *.js misses nearly all of
 * it. This pulls the inline blocks out and checks those too, then verifies the
 * things that have actually broken here before: a referenced asset that does
 * not exist, and record data pasted into an inline event handler.
 */
import { readFileSync, existsSync, readdirSync, writeFileSync, unlinkSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";

const ROOT = process.cwd();
const HTML = readdirSync(ROOT).filter((f) => f.endsWith(".html"));
const JS = readdirSync(ROOT).filter((f) => f.endsWith(".js"));

let failures = 0;
const fail = (file, msg) => { console.error(`FAIL ${file}: ${msg}`); failures++; };
const pass = (msg) => console.log(`  ok  ${msg}`);

/* ---------- 1. every .js file parses ---------- */
console.log("\n[1] standalone scripts parse");
for (const f of JS) {
  try {
    execFileSync(process.execPath, ["--check", join(ROOT, f)], { stdio: "pipe" });
    pass(f);
  } catch (e) {
    fail(f, "syntax error\n" + (e.stderr?.toString() ?? e.message));
  }
}

/* ---------- 2. inline <script> blocks parse ---------- */
console.log("\n[2] inline script blocks parse");
for (const f of HTML) {
  const src = readFileSync(join(ROOT, f), "utf8");
  // Only blocks with a body; <script src=...> has nothing to check.
  const blocks = [...src.matchAll(/<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/g)];
  if (blocks.length === 0) { pass(`${f} (no inline blocks)`); continue; }
  blocks.forEach((m, i) => {
    // A module is parsed differently from a classic script - import at top
    // level is a syntax error in one and required in the other - so the
    // extension has to match what the tag declares.
    const isModule = /type\s*=\s*["']module["']/.test(m[1]);
    const path = join(tmpdir(), `magpms-${f}-${i}.${isModule ? "mjs" : "js"}`);
    writeFileSync(path, m[2]);
    try {
      execFileSync(process.execPath, ["--check", path], { stdio: "pipe" });
      pass(`${f} block ${i}`);
    } catch (e) {
      fail(f, `inline block ${i} syntax error\n` + (e.stderr?.toString() ?? e.message));
    } finally {
      unlinkSync(path);
    }
  });
}

/* ---------- 3. referenced local assets exist ---------- */
console.log("\n[3] local asset references resolve");
for (const f of HTML) {
  const src = readFileSync(join(ROOT, f), "utf8");
  const refs = [
    ...[...src.matchAll(/<script[^>]*\bsrc="([^"]+)"/g)].map((m) => m[1]),
    ...[...src.matchAll(/<link[^>]*\bhref="([^"]+)"/g)].map((m) => m[1]),
  ].filter((r) => !/^https?:\/\//.test(r));

  for (const ref of refs) {
    if (existsSync(join(ROOT, dirname(f), ref))) pass(`${f} -> ${ref}`);
    else fail(f, `references missing asset "${ref}"`);
  }
}

/* ---------- 4. no record data inside inline event handlers ---------- */
console.log("\n[4] no template interpolation in inline event handlers");
/* An inline handler concatenates its argument into JavaScript source, so a
   value containing an apostrophe terminates the string early and the rest is
   parsed as code. HTML-escaping does not help: the parser decodes entities
   before the handler body is compiled. Use a data-* attribute and a delegated
   listener instead. */
for (const f of HTML) {
  const src = readFileSync(join(ROOT, f), "utf8");
  const bad = src
    .split("\n")
    .map((line, n) => [n + 1, line])
    .filter(([, line]) => /\son[a-z]+="[^"]*\$\{/.test(line));

  if (bad.length === 0) pass(f);
  else for (const [n, line] of bad) fail(f, `line ${n}: interpolation in inline handler\n      ${line.trim()}`);
}

/* ---------- 5. no fuel names written into the pages ---------- */
console.log("\n[5] fuel names come from the database, not the markup");
/* The original app had Diesel and Petrol typed into the markup in three
   places: two price inputs, two literal admin_set_price calls, and a pair of
   <option> tags in the till. A station selling anything else could not price
   it and, worse, could not ring it up at all - the sale simply could not be
   recorded. Fuels now come from get_prices, so adding or renaming one is an
   UPDATE rather than a code change.
   That is easy to undo by hand, and nothing else here would notice, so this
   fails the build if a fuel name reappears where a control is defined. */
const FUELS = ["Diesel", "Petrol", "Benzil", "Nafta", "Kerosene", "Benzin"];

/* Narrow on purpose. Prose may name a fuel - a card explaining how pricing
   works is not the bug - so only the places that would define a control
   count: an <option>, a value= or data-fuel= attribute, and a quoted string
   in script. Word boundaries matter: the company is called Mohamed Abdu Hirna
   Gomeju Petroleum, and "Petroleum" must not read as "Petrol". */
const patterns = (fuel) => [
  [new RegExp(`<option\\b[^>]*>\\s*${fuel}\\b`, "i"), "an <option>"],
  [new RegExp(`\\b(?:value|data-fuel)\\s*=\\s*["']${fuel}\\b`, "i"), "a value/data-fuel attribute"],
  [new RegExp(`["']${fuel}\\b["']`), "a quoted string"],
];

for (const f of HTML) {
  const src = readFileSync(join(ROOT, f), "utf8");
  const bad = [];
  src.split("\n").forEach((line, i) => {
    for (const fuel of FUELS) {
      for (const [re, where] of patterns(fuel)) {
        if (re.test(line)) bad.push([i + 1, fuel, where, line.trim()]);
      }
    }
  });

  if (bad.length === 0) pass(f);
  else
    for (const [n, fuel, where, line] of bad)
      fail(f, `line ${n}: "${fuel}" hard-coded in ${where} - build it from get_prices instead\n      ${line}`);
}

/* ---------------------------------------------------------------
 * [6] install parts stay pasteable, and whole
 * ---------------------------------------------------------------
 * These are run by copying them into the Supabase SQL editor on a phone. A
 * part of 206 lines was silently truncated mid-function on paste, and the
 * database answered "unterminated dollar-quoted string" - which reads as a
 * broken file rather than a short paste.
 *
 * An odd number of $$ markers means a function body was cut in half, which is
 * the shape that failure takes and the one worth refusing outright.
 */
const PARTS_DIR = join(ROOT, "supabase", "install_parts");
/* 180, from evidence rather than taste: parts of 164 and 167 lines pasted
   whole on the phone this is actually run from, and one of 206 was truncated
   mid-function. The limit sits above what is known to work and below what is
   known to fail. Move it if the evidence moves. */
const MAX_LINES = 180;

if (existsSync(PARTS_DIR)) {
  console.log("\n[6] install parts are pasteable on a phone");
  const parts = readdirSync(PARTS_DIR).filter(f => f.endsWith(".sql")).sort();
  let partsBad = 0;

  for (const f of parts) {
    const src = readFileSync(join(PARTS_DIR, f), "utf8");
    const lines = src.split("\n").length;
    const markers = (src.match(/\$\$/g) || []).length;

    if (lines > MAX_LINES) {
      fail(`install_parts/${f}`,
        `${lines} lines - over ${MAX_LINES}, split it before a phone truncates the paste`);
      partsBad++;
    }
    if (markers % 2 !== 0) {
      fail(`install_parts/${f}`,
        `${markers} dollar-quote markers - a function body is cut in half`);
      partsBad++;
    }
    /* A transaction split across files rolls back silently when the editor
       disconnects. Every part is standalone for that reason. */
    if (/^\s*begin;\s*$/m.test(src) || /^\s*commit;\s*$/m.test(src)) {
      fail(`install_parts/${f}`, "carries begin/commit - a transaction must not span parts");
      partsBad++;
    }
  }
  if (partsBad === 0) pass(`${parts.length} parts, all under ${MAX_LINES} lines and balanced`);
}

console.log(
  failures === 0
    ? "\nAll checks passed."
    : `\n${failures} check${failures === 1 ? "" : "s"} failed.`
);
process.exit(failures === 0 ? 0 : 1);
