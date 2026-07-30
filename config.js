/* MAGPMS Cloud - Supabase connection and RPC helper.
 *
 * PROJECT REF: fendopitdcyoefpxuevd
 *
 * Check this against the address bar before running SQL anywhere.
 *
 * This is the third project this app has pointed at in a day. The first became
 * unreachable - the browser was signed into a second Supabase account. The
 * second turned out to belong to a different application entirely; a check for
 * two named tables reported it empty when it was full of someone else's.
 *
 * The check that actually works asks what IS there, not whether one thing is:
 *
 *   select coalesce(string_agg(table_name, ', ' order by table_name), '(none)')
 *     from information_schema.tables where table_schema = 'public';
 *
 * Identity comes from Supabase Auth, not from localStorage. Every request
 * carries the signed-in user's JWT, so the database knows who is calling and
 * which station they belong to. No function takes a caller id as a parameter.
 *
 * The publishable key below is safe to ship ONLY because row level security
 * is enabled and the anon role has no direct table access - the RPCs are the
 * only way in. See supabase/migrations/0004_lockdown.sql.
 */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

export const SUPABASE_URL = "https://fendopitdcyoefpxuevd.supabase.co";
export const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_qVxWQXxOCfLSxWAF1mg1Gg_odcPAs1o";

export const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true }
});

/* Calls a database function. Rejects on failure rather than handing the error
   body back as if it were data - the old client returned res.json() without
   checking status, so a 401 looked like a successful empty result. */
export async function rpc(fn, params) {
  const { data, error } = await supabase.rpc(fn, params || {});
  if (error) {
    const err = new Error(error.message || "request failed");
    err.name = "RpcError";
    err.fn = fn;
    err.code = error.code;
    err.details = error.details;
    throw err;
  }
  return data;
}

/* The signed-in staff row, or null. Cached for the page's lifetime - it is
   read on nearly every render and does not change while a page is open. */
let _me = null;
export async function me({ refresh = false } = {}) {
  if (_me && !refresh) return _me;
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) return null;
  const rows = await rpc("me");
  _me = Array.isArray(rows) ? rows[0] : rows;
  return _me;
}

export async function signIn(email, password) {
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    /* Carry the status across. Re-wrapping in a bare Error loses it, and the
       status is the only reliable way to recognise a rate-limit refusal -
       those come back with an empty body whose message is the string "{}". */
    const e = new Error(error.message);
    e.name = "AuthError";
    e.status = error.status;
    throw e;
  }
  _me = null;
  return me();
}

export async function signOut() {
  _me = null;
  await supabase.auth.signOut();
}

/* Sends the browser to the login page unless a session exists and the staff
   row is approved. Returns the staff row when the guard passes.
   This is convenience, not security - the database enforces access. */
export async function requireStaff({ admin = false } = {}) {
  const staff = await me().catch(() => null);
  if (!staff || staff.status !== "approved") {
    location.replace("index.html");
    return null;
  }
  if (admin && staff.role !== "admin") {
    location.replace("staff.html");
    return null;
  }
  return staff;
}
