-- MAGPMS install 41 of 41 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Research, part 2: the rows underneath - every sale a cashier entered, as
-- entered, including the voided ones. Admin only.
set search_path = public, extensions;

-- total_rows is the size of the whole match, carried on every row by a
-- window. Without it the page can only say "500 rows" when it asked for 500
-- and got them - which reads as a total and is not one.
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

grant execute on function research_sales(uuid, date, date, uuid, text, int, int)
  to authenticated;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select sold_at, station_name, staff_name, nozzle_label, fuel_type,
--          liters, unit_price, total_etb, payment_method, voided, total_rows
--     from research_sales(null, current_date - 29, current_date) limit 5;
--
-- total_rows is the same on every row and is the size of the whole match,
-- not of the page.
