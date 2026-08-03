-- MAGPMS install 40 of 44 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Research, part 1: the shape of the trade - by day, week or month, per
-- branch, per fuel. Admin only.
set search_path = public, extensions;

create or replace function research_totals(
  p_station_id uuid  default null,
  p_from       date  default null,
  p_to         date  default null,
  p_bucket     text  default 'day')
returns table (
  bucket_start date, bucket_label text,
  station_id uuid, station_name text, fuel_type text,
  sale_count int, liters numeric, sales_etb numeric,
  credit_etb numeric, voided_count int, voided_liters numeric)
language sql stable security definer set search_path = public
as $$
  with args as (
    select coalesce(p_from, (now() at time zone app_timezone())::date - 29) as d_from,
           coalesce(p_to,   (now() at time zone app_timezone())::date)      as d_to,
           -- An unrecognised bucket falls back to the day rather than
           -- erroring. A typo should not be able to empty the page.
           case lower(coalesce(p_bucket, 'day'))
             when 'week'  then 'week'
             when 'month' then 'month'
             else 'day' end as bucket
  ),
  rows as (
    select (s.created_at at time zone app_timezone())::date as local_day,
           s.station_id, s.fuel_type, s.liters, s.total_etb,
           s.payment_method, coalesce(s.voided, false) as voided
      from sales s
     cross join args a
     where is_admin()
       and (p_station_id is null or s.station_id = p_station_id)
       and (s.created_at at time zone app_timezone())::date between a.d_from and a.d_to
  )
  select date_trunc(a.bucket, r.local_day::timestamp)::date,
         case a.bucket
           when 'month' then to_char(r.local_day, 'YYYY-MM')
           when 'week'  then 'week of ' ||
                             to_char(date_trunc('week', r.local_day::timestamp), 'YYYY-MM-DD')
           else to_char(r.local_day, 'YYYY-MM-DD') end,
         r.station_id, st.name, r.fuel_type,
         count(*) filter (where not r.voided)::int,
         coalesce(sum(r.liters) filter (where not r.voided), 0),
         coalesce(sum(r.total_etb) filter (where not r.voided), 0),
         coalesce(sum(r.total_etb) filter (where not r.voided
                                             and r.payment_method = 'credit'), 0),
         -- A void is a correction, not a negative sale, so it stays out of
         -- the money. But a branch voiding a lot of them is worth knowing,
         -- and that is invisible if voids are simply dropped.
         count(*) filter (where r.voided)::int,
         coalesce(sum(r.liters) filter (where r.voided), 0)
    from rows r
    cross join args a
    join stations st on st.id = r.station_id
   group by 1, 2, 3, 4, 5
   order by 1 desc, 4, 5;
$$;

grant execute on function research_totals(uuid, date, date, text) to authenticated;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select bucket_label, station_name, fuel_type, sale_count, liters, sales_etb
--     from research_totals(null, current_date - 29, current_date, 'week');
--
-- One row per week per branch per fuel.
