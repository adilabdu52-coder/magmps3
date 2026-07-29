-- 0008 — make "today" mean today here
--
-- THE BUG
--
-- Three functions decide what counts as today with date_trunc('day', now()).
-- Postgres stores timestamptz in UTC, so that is midnight UTC — which is 3am
-- in Ethiopia. Between local midnight and 3am every morning:
--
--   * admin_dashboard's "Sales today" tile still shows YESTERDAY's takings,
--     and keeps adding this morning's sales onto them.
--   * my_sales_today shows a cashier on the early shift somebody else's
--     numbers from the day before, and their own work counts as nothing until
--     3am.
--
-- It is wrong every single day, not on an edge case, and it is wrong in the
-- direction that matters: an owner reading the dashboard at 6am sees a figure
-- that mixes two days.
--
-- 0007's report_sales already grouped by local date, which is why the report
-- and the dashboard tile disagreed. This is the other half of that fix.
--
-- Nothing about the stored data changes. created_at is still timestamptz in
-- UTC, as it should be. Only the boundary used to read it back moves.

begin;

-- ---------------------------------------------------------------
-- one place that knows where the station is
-- ---------------------------------------------------------------
-- The timezone was a string literal repeated in each function, which is how
-- three copies drift apart. If the group ever operates outside Ethiopia, this
-- is the one line to change.
create or replace function app_timezone()
returns text
language sql immutable
as $$ select 'Africa/Addis_Ababa' $$;

-- Local midnight, expressed as the timestamptz to compare created_at against.
-- Read it inside out: now() converted to local wall-clock time, truncated to
-- the start of that day, then read back as an absolute instant.
create or replace function local_day_start()
returns timestamptz
language sql stable
as $$
  select date_trunc('day', now() at time zone app_timezone()) at time zone app_timezone();
$$;

-- ---------------------------------------------------------------
-- the three callers
-- ---------------------------------------------------------------
-- Bodies are otherwise unchanged from 0004; only the day boundary moves.
create or replace function admin_dashboard()
returns table (
  station_id uuid, station_name text, town text,
  sales_today_etb numeric, liters_today numeric,
  stock_liters numeric, capacity_liters numeric,
  credit_etb numeric, on_duty int, low_tanks int
)
language sql stable security definer set search_path = public
as $$
  select st.id, st.name, st.town,
    coalesce((select sum(s.total_etb) from sales s
              where s.station_id = st.id and not coalesce(s.voided,false)
                and s.created_at >= local_day_start()), 0),
    coalesce((select sum(s.liters) from sales s
              where s.station_id = st.id and not coalesce(s.voided,false)
                and s.created_at >= local_day_start()), 0),
    coalesce((select sum(t.current_liters)  from tanks t where t.station_id = st.id), 0),
    coalesce((select sum(t.capacity_liters) from tanks t where t.station_id = st.id), 0),
    coalesce((select sum(c.balance) from credit_customers c where c.station_id = st.id), 0),
    coalesce((select count(*)::int from attendance a
              where a.station_id = st.id and a.check_out is null), 0),
    coalesce((select count(*)::int from tanks t
              where t.station_id = st.id and t.capacity_liters > 0
                and (t.current_liters / t.capacity_liters) < 0.30), 0)
  from stations st
  where is_admin() or st.id = current_station()
  order by st.name;
$$;

create or replace function my_sales_today()
returns table (id uuid, fuel_type text, liters numeric, total_etb numeric,
               payment_method text, voided boolean, created_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select s.id, s.fuel_type, s.liters, s.total_etb, s.payment_method,
         coalesce(s.voided,false), s.created_at
  from sales s
  where s.staff_id = (select id from current_staff())
    and s.created_at >= local_day_start()
  order by s.created_at desc;
$$;

-- report_sales gains nothing in behaviour here - it was already grouping in
-- local time - but it stops carrying its own copy of the timezone name.
create or replace function report_sales(
  p_station_id uuid default null,
  p_from date default null,
  p_to   date default null)
returns table (
  day date, station_id uuid, station_name text, fuel_type text,
  sale_count int, liters numeric, sales_etb numeric)
language sql stable security definer set search_path = public
as $$
  with bounds as (
    select coalesce(p_from, (now() at time zone app_timezone())::date - 29) as d_from,
           coalesce(p_to,   (now() at time zone app_timezone())::date)      as d_to
  )
  select (s.created_at at time zone app_timezone())::date,
         s.station_id, st.name, s.fuel_type,
         count(*)::int, sum(s.liters), sum(s.total_etb)
    from sales s
    join stations st on st.id = s.station_id
   cross join bounds b
   where s.station_id = case when is_admin() then coalesce(p_station_id, s.station_id)
                             else current_station() end
     and not coalesce(s.voided, false)
     and (s.created_at at time zone app_timezone())::date between b.d_from and b.d_to
   group by 1, 2, 3, 4
   order by 1 desc, 3, 4;
$$;

commit;

grant execute on function app_timezone()     to authenticated;
grant execute on function local_day_start()  to authenticated;

-- ===============================================================
-- VERIFY
-- ===============================================================
-- 1. The boundary is local midnight, and it is three hours before UTC's:
--
--      select local_day_start(),
--             date_trunc('day', now()) as old_utc_boundary,
--             date_trunc('day', now()) - local_day_start() as difference;
--
--    difference must be 03:00:00. If it is 00:00:00 the server is already on
--    Africa/Addis_Ababa and nothing was broken; if it is anything else, check
--    what app_timezone() returns.
--
-- 2. The dashboard tile and the report now agree for today:
--
--      select sum(sales_today_etb) from admin_dashboard();
--      select sum(sales_etb) from report_sales(
--        null, (now() at time zone app_timezone())::date,
--              (now() at time zone app_timezone())::date);
--
--    These must match. Before this migration they differed for any sale made
--    between local midnight and 3am.
--
-- 3. The clearest proof, if you can run it between midnight and 3am local:
--    record a sale, then check that it appears in the till's "My Day" total.
--    Before this it would not have, until 3am.
