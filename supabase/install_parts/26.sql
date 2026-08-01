-- MAGPMS install 26 of 26 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Shifts and attendance, part 2: nothing vanishes from the manager page.
-- list_shifts and list_attendance are DROPPED first - they gain a column,
-- and Postgres will not change a return type in place.
set search_path = public, extensions;
-- ---------------------------------------------------------------
-- what the admin sees
-- ---------------------------------------------------------------
-- LEFT JOIN, so a row with no branch appears instead of vanishing. The branch
-- test is written out rather than folded into a coalesce, because
-- `station_id = coalesce(null, station_id)` is false when station_id is null -
-- which is exactly how those rows disappeared.
--
-- These two must be DROPPED first, not replaced. Both gain an `abandoned`
-- column, and Postgres refuses to change a function's return type in place:
--
--   ERROR: cannot change return type of existing function
--   HINT:  Use DROP FUNCTION list_shifts(uuid,integer,integer) first.
--
-- On a database that has never had 0007 this is a no-op, which is why running
-- against a fresh schema did not catch it. The upgrade path is the one that
-- matters, and it is the one everybody actually runs.
--
-- Dropping loses the grants that 0005 issued with `grant execute on all
-- functions`, so they are re-issued at the end of this file. A silent loss of
-- execute permission would show up as "permission denied for function" on
-- the shifts page and nowhere else.
drop function if exists list_shifts(uuid, int, int);
drop function if exists list_attendance(uuid, int, int);

create or replace function list_shifts(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text,
  opened_at timestamptz, closed_at timestamptz,
  opening_meter numeric, closing_meter numeric,
  metered_liters numeric, sold_liters numeric, variance_liters numeric,
  abandoned boolean)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.station_id, coalesce(st.name, '(no branch)'), stf.full_name,
         sh.opened_at, sh.closed_at, sh.opening_meter, sh.closing_meter,
         case when sh.closing_meter is null then null
              else sh.closing_meter - sh.opening_meter end,
         coalesce(sold.liters, 0),
         case when sh.closing_meter is null then null
              else (sh.closing_meter - sh.opening_meter) - coalesce(sold.liters, 0) end,
         sh.abandoned
    from shifts sh
    left join stations st on st.id = sh.station_id
    left join staff stf on stf.id = sh.staff_id
    left join lateral (
      select sum(s.liters) as liters
        from sales s
       where s.staff_id = sh.staff_id
         and not coalesce(s.voided, false)
         and s.created_at >= sh.opened_at
         and s.created_at <  coalesce(sh.closed_at, now())
    ) sold on true
   where (case when is_admin()
               then (p_station_id is null or sh.station_id = p_station_id)
               else sh.station_id = current_station() end)
     and sh.opened_at >= now() - make_interval(days => greatest(1, p_days))
   order by sh.opened_at desc
   limit greatest(1, least(p_limit, 500));
$$;

-- hours is null for an abandoned row. Nobody knows when that person went
-- home, and a number here would be read as if somebody did.
create or replace function list_attendance(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text,
  check_in timestamptz, check_out timestamptz, hours numeric, abandoned boolean)
language sql stable security definer set search_path = public
as $$
  select a.id, a.station_id, coalesce(st.name, '(no branch)'), stf.full_name,
         a.check_in, a.check_out,
         case when a.abandoned then null
              else round((extract(epoch from (coalesce(a.check_out, now()) - a.check_in))
                          / 3600.0)::numeric, 2) end,
         a.abandoned
    from attendance a
    left join stations st on st.id = a.station_id
    left join staff stf on stf.id = a.staff_id
   where (case when is_admin()
               then (p_station_id is null or a.station_id = p_station_id)
               else a.station_id = current_station() end)
     and a.check_in >= now() - make_interval(days => greatest(1, p_days))
   order by a.check_in desc
   limit greatest(1, least(p_limit, 500));
$$;

-- Re-issued because the two functions above were dropped and recreated, which
-- takes their permissions with them.
grant execute on function list_shifts(uuid, int, int)     to authenticated;
grant execute on function list_attendance(uuid, int, int) to authenticated;
grant execute on function check_in()                      to authenticated;
grant execute on function check_out()                     to authenticated;
grant execute on function open_shift(numeric)             to authenticated;
grant execute on function close_shift(numeric)            to authenticated;
grant execute on function my_open_shift()                 to authenticated;
grant execute on function my_attendance_status()          to authenticated;



notify pgrst, 'reload schema';


