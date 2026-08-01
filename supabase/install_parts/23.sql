-- MAGPMS install 23 of 37 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Staff report: one row per person over a date range. Voided sales are out
-- of the money but counted on their own.
set search_path = public, extensions;
create or replace function report_staff(
  p_station_id uuid default null,
  p_from date default null,
  p_to   date default null)
returns table (
  staff_id uuid, staff_name text, station_id uuid, station_name text,
  sale_count int, liters numeric, sales_etb numeric,
  cash_etb numeric, credit_etb numeric,
  voided_count int, days_active int, best_day date)
language sql stable security definer set search_path = public
as $$
  with bounds as (
    select coalesce(p_from, (now() at time zone app_timezone())::date - 29) as d_from,
           coalesce(p_to,   (now() at time zone app_timezone())::date)      as d_to
  ),
  -- Every sale in range that this caller is allowed to see. An admin sees a
  -- branch or all of them; anyone else sees only their own branch, the same
  -- rule the rest of the reporting follows.
  scoped as (
    select s.*, (s.created_at at time zone app_timezone())::date as local_day
      from sales s
     cross join bounds b
     where s.station_id = case when is_admin() then coalesce(p_station_id, s.station_id)
                               else current_station() end
       and (s.created_at at time zone app_timezone())::date between b.d_from and b.d_to
  ),
  -- The day each person took the most money. Worked out separately because
  -- it is a per-day maximum, not something a single group by can reach.
  by_day as (
    select staff_id, station_id, local_day, sum(total_etb) as etb
      from scoped
     where not coalesce(voided, false)
     group by 1, 2, 3
  ),
  best as (
    select distinct on (staff_id, station_id) staff_id, station_id, local_day
      from by_day
     order by staff_id, station_id, etb desc, local_day desc
  )
  select st_f.id, st_f.full_name, sc.station_id, stn.name,
         count(*) filter (where not coalesce(sc.voided, false))::int,
         coalesce(sum(sc.liters)    filter (where not coalesce(sc.voided, false)), 0),
         coalesce(sum(sc.total_etb) filter (where not coalesce(sc.voided, false)), 0),
         coalesce(sum(sc.total_etb) filter (where not coalesce(sc.voided, false)
                                              and sc.payment_method <> 'credit'), 0),
         coalesce(sum(sc.total_etb) filter (where not coalesce(sc.voided, false)
                                              and sc.payment_method  = 'credit'), 0),
         count(*) filter (where coalesce(sc.voided, false))::int,
         count(distinct sc.local_day) filter (where not coalesce(sc.voided, false))::int,
         max(b.local_day)
    from scoped sc
    join staff st_f    on st_f.id = sc.staff_id
    left join stations stn on stn.id = sc.station_id
    left join best b   on b.staff_id = sc.staff_id and b.station_id = sc.station_id
   group by st_f.id, st_f.full_name, sc.station_id, stn.name
   order by 7 desc, 2;
$$;

grant execute on function report_staff(uuid, date, date) to authenticated;



notify pgrst, 'reload schema';


