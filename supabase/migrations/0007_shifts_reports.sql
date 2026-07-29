-- 0007 — shift and attendance oversight, and a sales report
--
-- Staff already record shifts and attendance from the till, but nothing reads
-- them back: the only functions over those tables were my_open_shift() and
-- my_attendance_status(), both scoped to the caller. An admin had no way to
-- see who was on duty yesterday or whether a shift's meter agreed with what
-- was rung up. That is what list_shifts and list_attendance add.
--
-- report_sales is the first function that aggregates rather than lists. It is
-- deliberately grouped at day x branch x fuel: fine enough to answer "how much
-- diesel did Adama move on the 12th", coarse enough that a month of trade is a
-- few dozen rows rather than a few thousand.
--
-- The two rules from 0004 still hold. No function takes a caller id, and
-- p_station_id is a filter, never a grant.

begin;

-- ---------------------------------------------------------------
-- shifts, with the meter checked against the till
-- ---------------------------------------------------------------
-- The point of recording an opening and closing meter is that the pump's own
-- count can be compared with the sales that were entered. metered_liters is
-- what the pump says moved; sold_liters is what was rung up while the shift
-- was open. A persistent gap in one direction is worth a conversation.
--
-- Both are null-safe: an open shift has no closing meter yet, so its variance
-- is null rather than a misleading negative number.
create or replace function list_shifts(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text,
  opened_at timestamptz, closed_at timestamptz,
  opening_meter numeric, closing_meter numeric,
  metered_liters numeric, sold_liters numeric, variance_liters numeric)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.station_id, st.name, stf.full_name,
         sh.opened_at, sh.closed_at, sh.opening_meter, sh.closing_meter,
         case when sh.closing_meter is null then null
              else sh.closing_meter - sh.opening_meter end,
         coalesce(sold.liters, 0),
         case when sh.closing_meter is null then null
              else (sh.closing_meter - sh.opening_meter) - coalesce(sold.liters, 0) end
    from shifts sh
    join stations st on st.id = sh.station_id
    left join staff stf on stf.id = sh.staff_id
    left join lateral (
      select sum(s.liters) as liters
        from sales s
       where s.staff_id = sh.staff_id
         and not coalesce(s.voided, false)
         and s.created_at >= sh.opened_at
         and s.created_at <  coalesce(sh.closed_at, now())
    ) sold on true
   where sh.station_id = case when is_admin() then coalesce(p_station_id, sh.station_id)
                              else current_station() end
     and sh.opened_at >= now() - make_interval(days => greatest(1, p_days))
   order by sh.opened_at desc
   limit greatest(1, least(p_limit, 500));
$$;

-- ---------------------------------------------------------------
-- attendance
-- ---------------------------------------------------------------
-- Hours run to now for anyone still checked in, so a shift in progress shows a
-- growing figure rather than a blank.
create or replace function list_attendance(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text,
  check_in timestamptz, check_out timestamptz, hours numeric)
language sql stable security definer set search_path = public
as $$
  select a.id, a.station_id, st.name, stf.full_name, a.check_in, a.check_out,
         round((extract(epoch from (coalesce(a.check_out, now()) - a.check_in))
                / 3600.0)::numeric, 2)
    from attendance a
    join stations st on st.id = a.station_id
    left join staff stf on stf.id = a.staff_id
   where a.station_id = case when is_admin() then coalesce(p_station_id, a.station_id)
                             else current_station() end
     and a.check_in >= now() - make_interval(days => greatest(1, p_days))
   order by a.check_in desc
   limit greatest(1, least(p_limit, 500));
$$;

-- ---------------------------------------------------------------
-- sales report
-- ---------------------------------------------------------------
-- A trading day here ends at local midnight, not at the server's. Postgres
-- stores timestamptz in UTC and Ethiopia is UTC+3, so grouping on the raw
-- timestamp would push the first three hours of every day into the day before
-- and make the busiest morning hours land in yesterday's total.
--
-- NOTE: admin_dashboard's "sales today" still uses date_trunc('day', now()),
-- which is UTC. Until that is changed the dashboard tile and this report will
-- disagree between midnight and 03:00 local. Changing it is a one-line edit to
-- 0004, left alone here so this migration only adds.
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
    select coalesce(p_from, (now() at time zone 'Africa/Addis_Ababa')::date - 29) as d_from,
           coalesce(p_to,   (now() at time zone 'Africa/Addis_Ababa')::date)      as d_to
  )
  select (s.created_at at time zone 'Africa/Addis_Ababa')::date,
         s.station_id, st.name, s.fuel_type,
         count(*)::int, sum(s.liters), sum(s.total_etb)
    from sales s
    join stations st on st.id = s.station_id
   cross join bounds b
   where s.station_id = case when is_admin() then coalesce(p_station_id, s.station_id)
                             else current_station() end
     and not coalesce(s.voided, false)
     and (s.created_at at time zone 'Africa/Addis_Ababa')::date between b.d_from and b.d_to
   group by 1, 2, 3, 4
   order by 1 desc, 3, 4;
$$;

-- Voided sales are excluded above rather than subtracted. A void is a
-- correction, not a negative sale, so it should leave no trace in a total.

commit;

-- ---------------------------------------------------------------
-- grants
-- ---------------------------------------------------------------
-- 0005 granted execute on the functions that existed then. These are new, so
-- they are granted explicitly rather than relying on that having been a
-- default. anon is not granted: it gets nothing here, and even if it called
-- one, current_station() and is_admin() both come back empty for a caller
-- with no session, so every filter above resolves to no rows.
grant execute on function list_shifts(uuid, int, int)     to authenticated;
grant execute on function list_attendance(uuid, int, int) to authenticated;
grant execute on function report_sales(uuid, date, date)  to authenticated;

-- ===============================================================
-- VERIFY
-- ===============================================================
-- 1. As an admin, with no arguments:
--
--      select * from list_shifts();
--      select * from list_attendance();
--      select * from report_sales();
--
--    Expect every branch. An empty result means no shifts have been opened
--    yet, not that the function is broken - check with:
--      select count(*) from shifts;
--
-- 2. As an admin, narrowed to one branch, then as an operator passing a
--    DIFFERENT branch's id:
--
--      select distinct station_name from list_shifts('<other-branch-uuid>');
--
--    The admin must see the branch they asked for. The operator must still
--    see only their own - that is the filter-not-a-grant rule, and it is
--    worth re-checking here because these are the first new read functions
--    since the lockdown.
--
-- 3. Variance sanity, on a closed shift:
--
--      select staff_name, metered_liters, sold_liters, variance_liters
--        from list_shifts(null, 30) where closed_at is not null;
--
--    variance_liters should be metered minus sold. A large positive number
--    means fuel left the pump without a sale being entered.
