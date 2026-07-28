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

console.log(
  failures === 0
    ? "\nAll checks passed."
    : `\n${failures} check${failures === 1 ? "" : "s"} failed.`
);
process.exit(failures === 0 ? 0 : 1);
