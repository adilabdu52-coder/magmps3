-- 0005 — close the direct table door
--
-- Run this LAST, and do not skip it.
--
-- The functions in 0004 are only a boundary if the tables are not readable
-- directly. The publishable key in config.js is designed to be public, but
-- that is only safe when the database refuses anonymous table access. Without
-- this migration, anyone with the key can read every row over
-- /rest/v1/<table> regardless of what the RPCs check - which is how the old
-- debug.html was able to dump staff, sales and customers with no login.

begin;

alter table stations         enable row level security;
alter table staff            enable row level security;
alter table tanks            enable row level security;
alter table nozzles          enable row level security;
alter table sales            enable row level security;
alter table shifts           enable row level security;
alter table nozzle_readings  enable row level security;
alter table attendance       enable row level security;
alter table expenses         enable row level security;
alter table prices           enable row level security;
alter table credit_customers enable row level security;
alter table price_history    enable row level security;

-- No policies are defined on purpose. With RLS on and no policy, every direct
-- read and write is denied, and the SECURITY DEFINER functions - which run as
-- their owner and bypass RLS - become the only way in. That is the intent:
-- one audited path, not a second unguarded one.

revoke all on all tables in schema public from anon, authenticated;
grant execute on all functions in schema public to authenticated;

-- Signup is the one thing an unauthenticated caller must reach.
grant execute on function register_staff(text, text) to anon;

commit;

-- VERIFY afterwards. From a browser console on the site, signed out:
--
--   await fetch(`${SUPABASE_URL}/rest/v1/staff?select=*`,
--     { headers: { apikey: KEY, Authorization: `Bearer ${KEY}` } }).then(r => r.status)
--
-- Expect 401 or an empty array - never a list of staff. Run the same against
-- sales, credit_customers and expenses.
--
-- Then confirm the RPCs still refuse a forged caller: sign in as an operator
-- and call admin_set_price. It should return "not authorised" rather than
-- changing a price, because is_admin() reads the database and not the request.
