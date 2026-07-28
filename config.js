/* MAGPMS Cloud - Supabase connection and RPC helper.
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

export const SUPABASE_URL = "https://vpakcpketkuuwmnmritg.supabase.co";
export const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_dWTbItoNrx0zaAFXlHXzKA_Zp_kk2a9";

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
  if (error) throw new Error(error.message);
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
