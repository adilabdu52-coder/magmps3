-- 0021 — research: the shape of the trade, and the rows underneath it
--
-- Reports answers two fixed questions: how did the business do (day by branch
-- by fuel) and how is each person doing. Both are day-grained, both drop
-- voided sales, and neither will show you a single sale.
--
-- Research is for the question you have not asked yet. Two functions:
--
--   research_totals  the shape - by day, week or month, per branch, per fuel
--   research_sales   the rows behind it - every sale a cashier entered, as
--                    entered, including the voided ones
--
-- Those two go together deliberately. A total nobody can drill into is a
-- number you either believe or do not; being able to go from "Hirna, week of
-- the 27th, Diesel, 4,100 L" to the forty sales that make it up is the
-- difference between a report and something you can research with.
--
-- VOIDED SALES ARE INCLUDED HERE, FLAGGED, NOT DROPPED.
-- Everywhere else in the app a void is excluded from the money, which is
-- right: a void is a correction, not a negative sale. But research is for
-- looking at what happened, and what happened includes the mistakes. They are
-- counted in their own columns and marked on their own rows, so they can
-- never be added into takings by accident.
--
-- Admin only. Reports lets a cashier see their own branch; this does not,
-- because row-level access to every sale at every branch is a different
-- thing from a summary of your own.

begin;

-- ---------------------------------------------------------------
-- the shape
-- ---------------------------------------------------------------
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
         count(*) filter (where r.voided)::int,
         coalesce(sum(r.liters) filter (where r.voided), 0)
    from rows r
    cross join args a
    join stations st on st.id = r.station_id
   group by 1, 2, 3, 4, 5
   order by 1 desc, 4, 5;
$$;

-- ---------------------------------------------------------------
-- the rows underneath
-- ---------------------------------------------------------------
-- total_rows is the size of the whole match, carried on every row by a
-- window. Without it the page can only say "1,000 rows" when it asked for
-- 1,000 and got them - which reads as a total and is not one.
create or replace function research_sales(
  p_station_id uuid default null,
  p_from       date default null,
  p_to         date default null,
  p_staff_id   uuid default null,
  p_fuel       text default null,
  p_limit      int  default 500,
  p_offset     int  default 0)
returns table (
  id uuid, sold_at timestamptz, station_name text, staff_name text,
  nozzle_label text, fuel_type text, liters numeric, unit_price numeric,
  total_etb numeric, payment_method text, customer_name text,
  voided boolean, total_rows bigint)
language sql stable security definer set search_path = public
as $$
  with args as (
    select coalesce(p_from, (now() at time zone app_timezone())::date - 29) as d_from,
           coalesce(p_to,   (now() at time zone app_timezone())::date)      as d_to
  )
  select s.id, s.created_at, st.name, stf.full_name,
         coalesce(n.label, '-'), s.fuel_type, s.liters,
         -- What it actually went out at, not today's price. A sale is
         -- evidence of the price on the day, and re-pricing it with the
         -- current one would quietly rewrite history.
         case when s.liters > 0 then round(s.total_etb / s.liters, 2) end,
         s.total_etb, s.payment_method, cc.name,
         coalesce(s.voided, false),
         count(*) over ()
    from sales s
   cross join args a
    left join stations st on st.id = s.station_id
    left join staff stf   on stf.id = s.staff_id
    left join nozzles n   on n.id = s.nozzle_id
    left join credit_customers cc on cc.id = s.credit_customer_id
   where is_admin()
     and (p_station_id is null or s.station_id = p_station_id)
     and (p_staff_id is null or s.staff_id = p_staff_id)
     and (p_fuel is null or s.fuel_type = p_fuel)
     and (s.created_at at time zone app_timezone())::date between a.d_from and a.d_to
   order by s.created_at desc
   limit greatest(1, least(coalesce(p_limit, 500), 2000))
  offset greatest(0, coalesce(p_offset, 0));
$$;

grant execute on function research_totals(uuid, date, date, text)          to authenticated;
grant execute on function research_sales(uuid, date, date, uuid, text, int, int)
  to authenticated;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
-- Signed in as an admin:
--
--   select bucket_label, station_name, fuel_type, sale_count, liters, sales_etb
--     from research_totals(null, current_date - 29, current_date, 'week');
--
-- One row per week per branch per fuel.
--
--   select sold_at, station_name, staff_name, nozzle_label, fuel_type,
--          liters, unit_price, total_etb, payment_method, voided, total_rows
--     from research_sales(null, current_date - 29, current_date) limit 5;
--
-- total_rows is the same on every row and is the size of the whole match,
-- not of the page.
