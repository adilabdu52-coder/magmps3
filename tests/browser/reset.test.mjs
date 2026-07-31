/* The password-reset flow, against a stubbed Supabase auth client.
   Covers all three recovery-link shapes, since which one a project sends
   depends on when its email templates were last touched. */
import { chromium } from "playwright";
import { spawn } from "node:child_process";

const ROOT = process.env.MAGPMS_ROOT ?? new URL("../..", import.meta.url).pathname;
const PORT = 8732;
const BASE = `http://127.0.0.1:${PORT}`;

let failures = 0;
const ok = (name, cond, extra = "") => {
  if (cond) console.log(`  ok    ${name}`);
  else { failures++; console.log(`  FAIL  ${name}${extra ? "\n        " + extra : ""}`); }
};

const STUB = `
export function createClient() {
  const cfg = window.__STUB__ = window.__STUB__ || {};
  window.__calls = [];
  const log = (...a) => window.__calls.push(a);
  return {
    auth: {
      getSession: async () => ({ data: { session: cfg.session ?? null } }),
      signInWithPassword: async () => ({ error: null }),
      signOut: async () => { log("signOut"); cfg.session = null; return {}; },
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      resetPasswordForEmail: async (email, opts) => {
        log("resetPasswordForEmail", email, opts && opts.redirectTo);
        return { error: cfg.resetError
          ? { message: cfg.resetError, status: cfg.resetStatus } : null };
      },
      verifyOtp: async (a) => {
        log("verifyOtp", a.token_hash, a.type);
        if (cfg.verifyError) return { error: { message: cfg.verifyError } };
        cfg.session = { access_token: "stub" };
        return { error: null };
      },
      exchangeCodeForSession: async (c) => {
        log("exchangeCodeForSession", c);
        if (cfg.exchangeError) return { error: { message: cfg.exchangeError } };
        cfg.session = { access_token: "stub" };
        return { error: null };
      },
      updateUser: async (a) => {
        log("updateUser", a.password);
        return { error: cfg.updateError ? { message: cfg.updateError } : null };
      },
      /* signUp returns a session only when the project does not ask for
         e-mail confirmation. With confirmation on it hands back a user and
         NO session - that difference is the whole of section [7]. */
      signUp: async () => ({
        data: cfg.signupData ?? { user: { id: "u1" }, session: { access_token: "stub" } },
        error: cfg.signupError ? { message: cfg.signupError } : null
      })
    },
    /* register_staff answers with a JSON body whether it succeeded or
       refused, so the stub must be able to return a refusal that is not an
       error. Returning [] for every RPC hid exactly the failure the page was
       meant to catch. */
    rpc: async (fn) => {
      log(fn);
      return { data: (cfg.rpcResult && fn in cfg.rpcResult) ? cfg.rpcResult[fn] : [], error: null };
    }
  };
}`;

const server = spawn("python3", ["-m", "http.server", String(PORT), "--bind", "127.0.0.1"],
  { cwd: ROOT, stdio: "ignore" });
await new Promise(r => setTimeout(r, 700));

const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
const errors = [];

async function open(url, stub = {}) {
  const ctx = await browser.newContext();
  await ctx.route(/esm\.sh/, r =>
    r.fulfill({ status: 200, contentType: "application/javascript", body: STUB }));
  const page = await ctx.newPage();
  page.on("pageerror", e => errors.push(`${url}: ${e}`));
  await page.addInitScript(s => { window.__STUB__ = s; }, stub);
  await page.goto(url);
  return { page, ctx };
}
const calls = p => p.evaluate(() => window.__calls);

console.log("\n[1] recovery link shapes");

{ // current default: ?token_hash
  const { page, ctx } = await open(`${BASE}/reset.html?token_hash=abc123&type=recovery`);
  await page.waitForSelector("#resetCard:not(.hidden)", { timeout: 5000 }).catch(() => {});
  ok("token_hash link opens the form", await page.locator("#resetCard").isVisible());
  const c = await calls(page);
  ok("verifyOtp called with the token and type",
     JSON.stringify(c).includes('"verifyOtp","abc123","recovery"'), JSON.stringify(c));
  ok("token removed from the address bar", !(await page.evaluate(() => location.search)));
  await ctx.close();
}

{ // PKCE: ?code
  const { page, ctx } = await open(`${BASE}/reset.html?code=pkce-xyz`);
  await page.waitForSelector("#resetCard:not(.hidden)", { timeout: 5000 }).catch(() => {});
  ok("PKCE code link opens the form", await page.locator("#resetCard").isVisible());
  ok("exchangeCodeForSession called",
     JSON.stringify(await calls(page)).includes('"exchangeCodeForSession","pkce-xyz"'));
  await ctx.close();
}

{ // implicit: the client establishes the session from the fragment itself
  const { page, ctx } = await open(`${BASE}/reset.html#access_token=t`, { session: { access_token: "t" } });
  await page.waitForSelector("#resetCard:not(.hidden)", { timeout: 5000 }).catch(() => {});
  ok("implicit fragment link opens the form", await page.locator("#resetCard").isVisible());
  await ctx.close();
}

console.log("\n[2] links that should not work");

{ // expired, as Supabase actually returns it
  const { page, ctx } = await open(
    `${BASE}/reset.html#error=access_denied&error_description=Email+link+is+invalid+or+has+expired`);
  await page.waitForSelector("#badLink:not(.hidden)", { timeout: 5000 }).catch(() => {});
  ok("expired link is refused", await page.locator("#badLink").isVisible());
  /* The server says "Email link is invalid or has expired". That is accurate
     and useless - it does not say what to do. authMessage trades the exact
     wording for a next step. */
  const t = await page.locator("#badMsg").textContent();
  ok("and says why, in plain words", /expired or was already used/i.test(t), t);
  ok("and what to do about it", /ask for a new one/i.test(t), t);
  ok("the form is not offered", await page.locator("#resetCard").isHidden());
  await ctx.close();
}

{ // no token at all, nobody signed in
  const { page, ctx } = await open(`${BASE}/reset.html`);
  await page.waitForSelector("#badLink:not(.hidden)", { timeout: 8000 }).catch(() => {});
  ok("bare page with no session is refused", await page.locator("#badLink").isVisible());
  ok("no password form for a stranger", await page.locator("#resetCard").isHidden());
  await ctx.close();
}

{ // verifyOtp itself rejects
  const { page, ctx } = await open(`${BASE}/reset.html?token_hash=used&type=recovery`,
    { verifyError: "Token has expired or is invalid" });
  await page.waitForSelector("#badLink:not(.hidden)", { timeout: 5000 }).catch(() => {});
  ok("a rejected token is explained, not quoted",
     /expired or was already used/i.test(await page.locator("#badMsg").textContent()));
  await ctx.close();
}

console.log("\n[3] setting the password");

{
  const { page, ctx } = await open(`${BASE}/reset.html?token_hash=t&type=recovery`);
  await page.waitForSelector("#resetCard:not(.hidden)", { timeout: 5000 });

  /* minlength="8" means the browser refuses to submit at all, so the handler
     never runs and #rsMsg stays empty. That is the correct outcome - the
     field is marked invalid and nothing reaches the server. The length check
     in JS still earns its place as the backstop for a value set some other
     way, but this is not the path that exercises it. */
  await page.fill("#rsPass", "short1");
  await page.fill("#rsPass2", "short1");
  await page.click("#rsBtn");
  ok("a short password never submits",
     await page.evaluate(() => !document.getElementById("rsPass").checkValidity()));
  ok("and nothing was sent", !JSON.stringify(await calls(page)).includes("updateUser"));

  await page.fill("#rsPass", "correct-horse");
  await page.fill("#rsPass2", "correct-hose");
  await page.click("#rsBtn");
  ok("a mismatch is refused",
     (await page.locator("#rsMsg").textContent()).includes("do not match"));
  ok("still nothing sent", !JSON.stringify(await calls(page)).includes("updateUser"));

  await page.fill("#rsPass", "correct-horse");
  await page.fill("#rsPass2", "correct-horse");
  await page.click("#rsBtn");
  await page.waitForFunction(() => JSON.stringify(window.__calls).includes("updateUser"), null, { timeout: 5000 });
  const c = JSON.stringify(await calls(page));
  ok("the new password is sent once", c.includes('"updateUser","correct-horse"'));
  ok("and the session is dropped afterwards", c.includes('"signOut"'));
  await page.waitForURL(/index\.html$/, { timeout: 5000 }).catch(() => {});
  ok("then back to sign in", /index\.html$/.test(page.url()), page.url());
  await ctx.close();
}

console.log("\n[4] asking for a link, from the login page");

{
  const { page, ctx } = await open(`${BASE}/index.html`, { session: null });
  await page.click("#toForgot");
  ok("the forgot card opens", await page.locator("#forgotCard").isVisible());
  ok("the sign-in card steps aside", await page.locator("#loginCard").isHidden());

  await page.fill("#fgEmail", "abebe@example.com");
  await page.click("#fgBtn");
  await page.waitForFunction(() => JSON.stringify(window.__calls).includes("resetPasswordForEmail"), null, { timeout: 5000 });
  const c = await calls(page);
  const call = c.find(x => x[0] === "resetPasswordForEmail");
  ok("sent for the address typed", call[1] === "abebe@example.com", JSON.stringify(call));
  ok("redirects back to this site's reset page", /\/reset\.html$/.test(call[2] || ""), call[2]);

  const shown = await page.locator("#fgMsg").textContent();
  ok("the reply does not confirm the account exists",
     !/no such|not found|unknown|does not exist/i.test(shown), shown);

  await page.click("#toLoginB");
  ok("and you can get back to sign in", await page.locator("#loginCard").isVisible());
  await ctx.close();
}

console.log("\n[5] signups closed");

{
  const { page, ctx } = await open(`${BASE}/index.html`,
    { session: null, signupError: "Signups not allowed for this instance" });
  await page.click("#toSignup");
  await page.fill("#suName", "Abebe Kebede");
  await page.fill("#suEmail", "a@b.com");
  await page.fill("#suPass", "password123");
  await page.click("#suBtn");
  await page.waitForFunction(() =>
    document.querySelector("#suMsg").textContent.length > 0, null, { timeout: 5000 });
  const t = await page.locator("#suMsg").textContent();
  ok("a closed door reads as a closed door", t.includes("Sign-ups are closed"), t);
  ok("not as a raw server error", !t.includes("instance"), t);
  await ctx.close();
}

console.log("\n[6] errors read as sentences, not JSON");

{ // the exact shape that put "{}" on screen: 429 with an empty body
  const { page, ctx } = await open(`${BASE}/index.html`,
    { session: null, resetError: "{}", resetStatus: 429 });
  await page.click("#toForgot");
  await page.fill("#fgEmail", "a@b.com");
  await page.click("#fgBtn");
  await page.waitForFunction(() =>
    document.querySelector("#fgMsg").textContent.length > 0, null, { timeout: 5000 });
  const t = await page.locator("#fgMsg").textContent();
  ok("an empty 429 body never reaches the screen", !t.includes("{}"), t);
  ok("it says what happened", /too many emails/i.test(t), t);
  ok("and what to do instead", /ask the manager/i.test(t), t);
  await ctx.close();
}

{ // same refusal, but worded rather than coded
  const { page, ctx } = await open(`${BASE}/index.html`,
    { session: null, resetError: "email rate limit exceeded" });
  await page.click("#toForgot");
  await page.fill("#fgEmail", "a@b.com");
  await page.click("#fgBtn");
  await page.waitForFunction(() =>
    document.querySelector("#fgMsg").textContent.length > 0, null, { timeout: 5000 });
  const t = await page.locator("#fgMsg").textContent();
  ok("recognised by wording as well as by status", /too many emails/i.test(t), t);
  await ctx.close();
}

{ // an unrecognised failure still gets a usable sentence
  const { page, ctx } = await open(`${BASE}/index.html`,
    { session: null, resetError: "[object Object]" });
  await page.click("#toForgot");
  await page.fill("#fgEmail", "a@b.com");
  await page.click("#fgBtn");
  await page.waitForFunction(() =>
    document.querySelector("#fgMsg").textContent.length > 0, null, { timeout: 5000 });
  const t = await page.locator("#fgMsg").textContent();
  ok("[object Object] falls back to plain words", !t.includes("object"), t);
  await ctx.close();
}

{ // a real message is passed through untouched
  const { page, ctx } = await open(`${BASE}/index.html`,
    { session: null, resetError: "Unable to validate email address: invalid format" });
  await page.click("#toForgot");
  await page.fill("#fgEmail", "a@b.com");
  await page.click("#fgBtn");
  await page.waitForFunction(() =>
    document.querySelector("#fgMsg").textContent.length > 0, null, { timeout: 5000 });
  const t = await page.locator("#fgMsg").textContent();
  ok("a genuine message is not swallowed", t.includes("invalid format"), t);
  await ctx.close();
}

console.log("\n[7] a signup that only looks successful");

/* This is the failure that cost a day. register_staff refuses by RETURNING
   {success:false}, which is a successful call carrying JSON - rpc() does not
   throw, so a caller that ignores the result prints "Account created" over a
   signup that created no staff row. Nothing showed it until the account was
   promoted and matched zero rows. */
const signup = async (page, email = "a@b.com") => {
  await page.click("#toSignup");
  await page.fill("#suName", "Abebe Kebede");
  await page.fill("#suEmail", email);
  await page.fill("#suPass", "password123");
  await page.click("#suBtn");
  await page.waitForFunction(() =>
    document.querySelector("#suMsg").textContent.length > 0, null, { timeout: 5000 });
  return page.locator("#suMsg").textContent();
};

{ // confirm-email on: a user, no session, so auth.uid() is null in the function
  const { page, ctx } = await open(`${BASE}/index.html`, {
    session: null,
    signupData: { user: { id: "u1" }, session: null },
    rpcResult: { register_staff: { success: false, message: "not authenticated" } }
  });
  const t = await signup(page);
  ok("a refused registration is never called success", !/Account created/i.test(t), t);
  ok("it says the login exists but the record does not", /staff record was not/i.test(t), t);
  ok("it names e-mail confirmation as the cause", /confirmation/i.test(t), t);
  /* Signing up again cannot work - the address is taken, so the second
     attempt fails at signUp instead, and the person is no better off. */
  ok("and does not invite a retry that cannot work", /do not sign up again/i.test(t), t);
  ok("the message is not raw JSON", !t.includes("success") && !t.includes("{"), t);
  await ctx.close();
}

{ // signing up twice on an account that already has its staff row
  const { page, ctx } = await open(`${BASE}/index.html`, {
    session: null,
    rpcResult: { register_staff: { success: false, message: "account already registered" } }
  });
  const t = await signup(page);
  ok("an existing account is not reported as created", !/Account created/i.test(t), t);
  ok("and points at approval, which is what is actually missing",
     /already exists/i.test(t) && /approve/i.test(t), t);
  await ctx.close();
}

{ // the ordinary path still works
  const { page, ctx } = await open(`${BASE}/index.html`, {
    session: null,
    rpcResult: { register_staff: { success: true, message: "awaiting admin approval" } }
  });
  const t = await signup(page);
  ok("a real signup still says so", /Account created/i.test(t), t);
  ok("and still asks for approval", /approve/i.test(t), t);
  ok("the form is cleared afterwards",
     await page.evaluate(() => document.getElementById("suEmail").value === ""));
  await ctx.close();
}

{ // an unrecognised refusal is passed through rather than swallowed
  const { page, ctx } = await open(`${BASE}/index.html`, {
    session: null,
    rpcResult: { register_staff: { success: false, message: "phone already in use" } }
  });
  const t = await signup(page);
  ok("an unknown refusal reaches the screen", /phone already in use/i.test(t), t);
  ok("and is not dressed up as success", !/Account created/i.test(t), t);
  await ctx.close();
}

ok("no uncaught page errors anywhere", errors.length === 0, errors.join("\n        "));

await browser.close();
server.kill();
console.log(failures ? `\n${failures} check(s) failed\n` : "\nAll checks passed\n");
process.exit(failures ? 1 : 0);
