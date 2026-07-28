-- 0005 — close the direct table door
--
-- Run this LAST, and do not skip it.
--
-- The functions in 0004 are only a boundary if the tables are not readable
-- directly. The publishable key in config.js is designed to be public, but
-- that is only safe when the database refuses anonymous table access.
-- Without this, anyone with the key can read every row over
-- /rest/v1/<table> regardless of what the functions check.

begin;

do $$
declare
  t text;
  all_tables text[] := array[
    'stations','staff','admins','tanks','sales','fuel_prices',
    'credit_customers','shifts','attendance','expenses','deliveries',
    'pumps','nozzles','nozzle_readings','price_history',
    'app_security_settings','danger_confirm_codes'
  ];
begin
  foreach t in array all_tables loop
    if to_regclass('public.' || t) is null then
      raise notice 'skipping %, table not present', t;
      continue;
    end if;
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

-- No policies are defined on purpose. With RLS on and no policy, every direct
-- read and write is denied, and the SECURITY DEFINER functions - which run as
-- their owner and bypass RLS - become the only way in. That is the intent:
-- one audited path, not a second unguarded one.

revoke all on all tables in schema public from anon, authenticated;
grant execute on all functions in schema public to authenticated;

-- Signup is the one thing an unauthenticated caller must reach.
grant execute on function register_staff(text, text) to anon;

commit;

-- ===============================================================
-- VERIFY
-- ===============================================================
-- 1. Signed out, from a browser console on the live site:
--
--      await fetch(`${SUPABASE_URL}/rest/v1/staff?select=*`,
--        { headers: { apikey: KEY, Authorization: `Bearer ${KEY}` } })
--        .then(r => r.status)
--
--    Expect 401, or an empty array - never a list of staff. Repeat for
--    sales, credit_customers and expenses.
--
-- 2. Signed in as an operator, call admin_set_price. It must return
--    "not authorised" rather than changing a price - is_admin() reads the
--    database, not the request.
--
-- 3. Signed in as an operator at one branch, call list_sales with another
--    branch's p_station_id. It must still return only their own branch.
--    That is the whole point of the station work: the parameter is a filter
--    for admins, never a grant.
