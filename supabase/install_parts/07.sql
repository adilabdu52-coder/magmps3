-- MAGPMS install 7 of 33 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

create or replace function list_tanks(p_station_id uuid default null)
returns table (id int, station_id uuid, tank_name text, fuel_type text,
               current_liters numeric, capacity_liters numeric)
language sql stable security definer set search_path = public
as $$
  select t.id, t.station_id, t.tank_name, t.fuel_type, t.current_liters, t.capacity_liters
  from tanks t
  where t.station_id = case when is_admin() then coalesce(p_station_id, t.station_id)
                            else current_station() end
  order by t.station_id, t.tank_name;
$$;

create or replace function list_sales(p_station_id uuid default null, p_limit int default 100)
returns table (id uuid, station_id uuid, station_name text, staff_name text,
               fuel_type text, liters numeric, total_etb numeric,
               payment_method text, voided boolean, created_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select s.id, s.station_id, st.name, stf.full_name, s.fuel_type, s.liters,
         s.total_etb, s.payment_method, coalesce(s.voided,false), s.created_at
  from sales s
  join stations st on st.id = s.station_id
  left join staff stf on stf.id = s.staff_id
  where s.station_id = case when is_admin() then coalesce(p_station_id, s.station_id)
                            else current_station() end
  order by s.created_at desc
  limit greatest(1, least(p_limit, 500));
$$;

create or replace function list_credit_customers(p_station_id uuid default null)
returns table (id uuid, station_id uuid, name text, phone text, plate_no text,
               credit_limit numeric, balance numeric)
language sql stable security definer set search_path = public
as $$
  select c.id, c.station_id, c.name, c.phone, c.plate_no, c.credit_limit, c.balance
  from credit_customers c
  where c.station_id = case when is_admin() then coalesce(p_station_id, c.station_id)
                            else current_station() end
  order by c.name;
$$;

create or replace function list_expenses(p_station_id uuid default null, p_limit int default 50)
returns table (id uuid, station_id uuid, station_name text, category text,
               description text, amount_etb numeric, created_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select e.id, e.station_id, st.name, e.category, e.description, e.amount_etb, e.created_at
  from expenses e
  join stations st on st.id = e.station_id
  where e.station_id = case when is_admin() then coalesce(p_station_id, e.station_id)
                            else current_station() end
  order by e.created_at desc
  limit greatest(1, least(p_limit, 500));
$$;

create or replace function price_history(p_station_id uuid default null, p_days int default 180)
returns table (fuel_type text, old_price numeric, new_price numeric,
               changed_at timestamptz, changed_by_name text)
language sql stable security definer set search_path = public
as $$
  select h.fuel_type, h.old_price, h.new_price, h.changed_at, s.full_name
  from price_history h
  left join staff s on s.id = h.changed_by
  where h.station_id = case when is_admin() then coalesce(p_station_id, h.station_id)
                            else current_station() end
    and h.changed_at >= now() - make_interval(days => greatest(1, p_days))
  order by h.changed_at;
$$;
