-- MAGPMS install 16 of 19 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

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

grant execute on function list_shifts(uuid, int, int)     to authenticated;

grant execute on function list_attendance(uuid, int, int) to authenticated;

grant execute on function report_sales(uuid, date, date)  to authenticated;

create or replace function app_timezone()
returns text
language sql immutable
as $$ select 'Africa/Addis_Ababa' $$;

create or replace function local_day_start()
returns timestamptz
language sql stable
as $$
  select date_trunc('day', now() at time zone app_timezone()) at time zone app_timezone();
$$;
