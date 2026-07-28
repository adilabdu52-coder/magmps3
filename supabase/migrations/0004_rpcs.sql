-- 0004 — the RPC contract the pages call
--
-- Two rules hold everywhere below:
--
--   1. No function takes the caller's id. Identity comes from current_staff().
--      The old app sent p_admin_id / p_staff_id from localStorage, so any
--      client could act as any user - and a cashier could file a shift or a
--      sale against a colleague.
--
--   2. p_station_id is a FILTER, never a grant. An admin may narrow to one
--      branch; everyone else is pinned to their own whatever they pass.

begin;

-- Reusable scope test: true when the caller may see this station's rows.
create or replace function can_see_station(p_station uuid)
returns boolean
language sql stable security definer set search_path = public
as $$ select is_admin() or p_station = current_station(); $$;

-- ---------- reference ----------
create or replace function list_stations()
returns table (id uuid, name text, town text)
language sql stable security definer set search_path = public
as $$
  select s.id, s.name, s.town from stations s
  where is_admin() or s.id = current_station()
  order by s.name;
$$;

-- ---------- dashboard ----------
-- One row per branch, so the admin rail is a single call rather than one per
-- site. Staff get exactly their own row from the same function.
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
              where s.station_id = st.id and not s.voided
                and s.created_at >= date_trunc('day', now())), 0),
    coalesce((select sum(s.liters) from sales s
              where s.station_id = st.id and not s.voided
                and s.created_at >= date_trunc('day', now())), 0),
    coalesce((select sum(t.current_liters)  from tanks t where t.station_id = st.id), 0),
    coalesce((select sum(t.capacity_liters) from tanks t where t.station_id = st.id), 0),
    coalesce((select sum(c.balance) from credit_customers c where c.station_id = st.id), 0),
    coalesce((select count(*)::int from attendance a
              where a.station_id = st.id and a.check_out is null), 0),
    coalesce((select count(*)::int from tanks t
              where t.station_id = st.id
                and t.capacity_liters > 0
                and (t.current_liters / t.capacity_liters) < 0.30), 0)
  from stations st
  where is_admin() or st.id = current_station()
  order by st.name;
$$;

-- ---------- reads, scoped ----------
create or replace function get_prices(p_station_id uuid default null)
returns table (fuel_type text, price_per_liter numeric)
language sql stable security definer set search_path = public
as $$
  select p.fuel_type, p.price_per_liter
  from prices p
  where p.station_id = case when is_admin() then coalesce(p_station_id, p.station_id)
                           else current_station() end
  order by p.fuel_type;
$$;

create or replace function list_tanks(p_station_id uuid default null)
returns table (id uuid, station_id uuid, tank_name text, fuel_type text,
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
         s.total_etb, s.payment_method, s.voided, s.created_at
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

-- ---------- the caller's own rows ----------
create or replace function my_sales_today()
returns table (id uuid, fuel_type text, liters numeric, total_etb numeric,
               payment_method text, voided boolean, created_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select s.id, s.fuel_type, s.liters, s.total_etb, s.payment_method, s.voided, s.created_at
  from sales s
  where s.staff_id = (select id from current_staff())
    and s.created_at >= date_trunc('day', now())
  order by s.created_at desc;
$$;

create or replace function my_open_shift()
returns table (id uuid, opened_at timestamptz, opening_meter numeric)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.opened_at, sh.opening_meter
  from shifts sh
  where sh.staff_id = (select id from current_staff()) and sh.closed_at is null
  order by sh.opened_at desc limit 1;
$$;

create or replace function my_attendance_status()
returns table (id uuid, check_in timestamptz, check_out timestamptz)
language sql stable security definer set search_path = public
as $$
  select a.id, a.check_in, a.check_out
  from attendance a
  where a.staff_id = (select id from current_staff())
  order by a.check_in desc limit 1;
$$;

-- ---------- staff writes ----------
create or replace function record_sale(
  p_fuel_type text, p_liters numeric, p_payment text,
  p_credit_customer_id uuid default null)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_staff staff := current_staff();
  v_station uuid;
  v_price numeric;
  v_tank uuid;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  v_station := v_staff.station_id;
  if v_station is null then
    return json_build_object('success', false, 'message', 'no branch assigned');
  end if;
  if not exists (select 1 from shifts where staff_id = v_staff.id and closed_at is null) then
    return json_build_object('success', false, 'message', 'open a shift first');
  end if;
  if not (p_liters > 0) then
    return json_build_object('success', false, 'message', 'litres must be positive');
  end if;

  select price_per_liter into v_price
  from prices where station_id = v_station and fuel_type = p_fuel_type;
  if v_price is null then
    return json_build_object('success', false, 'message', 'no price set for ' || p_fuel_type);
  end if;

  -- Credit customers belong to one branch.
  if p_payment = 'credit' then
    if p_credit_customer_id is null then
      return json_build_object('success', false, 'message', 'choose a credit customer');
    end if;
    if not exists (select 1 from credit_customers
                   where id = p_credit_customer_id and station_id = v_station) then
      return json_build_object('success', false, 'message', 'customer is not at this branch');
    end if;
  end if;

  select id into v_tank from tanks
  where station_id = v_station and fuel_type = p_fuel_type
  order by current_liters desc limit 1;
  if v_tank is null then
    return json_build_object('success', false, 'message', 'no tank holds ' || p_fuel_type);
  end if;
  if (select current_liters from tanks where id = v_tank) < p_liters then
    return json_build_object('success', false, 'message', 'not enough stock in the tank');
  end if;

  insert into sales (station_id, staff_id, fuel_type, liters, total_etb,
                     payment_method, credit_customer_id, price_per_liter)
  values (v_station, v_staff.id, p_fuel_type, p_liters, round(p_liters * v_price, 2),
          p_payment, p_credit_customer_id, v_price);

  update tanks set current_liters = current_liters - p_liters where id = v_tank;

  if p_payment = 'credit' then
    update credit_customers set balance = balance + round(p_liters * v_price, 2)
    where id = p_credit_customer_id;
  end if;

  return json_build_object('success', true, 'message', 'sale recorded');
end;
$$;

create or replace function open_shift(p_opening_meter numeric)
returns json
language plpgsql security definer set search_path = public
as $$
declare v_staff staff := current_staff();
begin
  if v_staff.id is null then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if exists (select 1 from shifts where staff_id = v_staff.id and closed_at is null) then
    return json_build_object('success', false, 'message', 'a shift is already open');
  end if;
  insert into shifts (station_id, staff_id, opening_meter, opened_at)
  values (v_staff.station_id, v_staff.id, p_opening_meter, now());
  return json_build_object('success', true, 'message', 'shift opened');
end;
$$;

create or replace function close_shift(p_closing_meter numeric)
returns json
language plpgsql security definer set search_path = public
as $$
declare v_staff staff := current_staff(); v_id uuid;
begin
  select id into v_id from shifts
  where staff_id = v_staff.id and closed_at is null order by opened_at desc limit 1;
  if v_id is null then return json_build_object('success', false, 'message', 'no open shift'); end if;
  update shifts set closing_meter = p_closing_meter, closed_at = now() where id = v_id;
  return json_build_object('success', true, 'message', 'shift closed');
end;
$$;

create or replace function check_in()
returns json
language plpgsql security definer set search_path = public
as $$
declare v_staff staff := current_staff();
begin
  if v_staff.id is null then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if exists (select 1 from attendance where staff_id = v_staff.id and check_out is null) then
    return json_build_object('success', false, 'message', 'already checked in');
  end if;
  insert into attendance (station_id, staff_id, check_in)
  values (v_staff.station_id, v_staff.id, now());
  return json_build_object('success', true, 'message', 'checked in');
end;
$$;

create or replace function check_out()
returns json
language plpgsql security definer set search_path = public
as $$
declare v_staff staff := current_staff(); v_id uuid;
begin
  select id into v_id from attendance
  where staff_id = v_staff.id and check_out is null order by check_in desc limit 1;
  if v_id is null then return json_build_object('success', false, 'message', 'not checked in'); end if;
  update attendance set check_out = now() where id = v_id;
  return json_build_object('success', true, 'message', 'checked out');
end;
$$;

-- ---------- admin writes ----------
create or replace function admin_set_price(p_station_id uuid, p_fuel_type text, p_price numeric)
returns json
language plpgsql security definer set search_path = public
as $$
declare v_admin staff := current_staff(); v_old numeric;
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if not (p_price > 0) then return json_build_object('success', false, 'message', 'price must be positive'); end if;

  select price_per_liter into v_old
  from prices where station_id = p_station_id and fuel_type = p_fuel_type;

  insert into prices (station_id, fuel_type, price_per_liter)
  values (p_station_id, p_fuel_type, p_price)
  on conflict (station_id, fuel_type)
  do update set price_per_liter = excluded.price_per_liter;

  -- The price and its history are written together, so the trail cannot
  -- silently miss a change.
  insert into price_history (station_id, fuel_type, old_price, new_price, changed_by)
  values (p_station_id, p_fuel_type, v_old, p_price, v_admin.id);

  return json_build_object('success', true, 'message', 'price updated');
end;
$$;

create or replace function admin_list_staff()
returns table (id uuid, full_name text, email text, phone text, role text,
               status text, station_id uuid)
language sql stable security definer set search_path = public
as $$
  select s.id, s.full_name, s.email, s.phone, s.role, s.status, s.station_id
  from staff s
  where is_admin()
  order by s.status, s.full_name;
$$;

create or replace function admin_set_staff_status(p_staff_id uuid, p_status text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if p_status not in ('pending','approved','rejected') then
    return json_build_object('success', false, 'message', 'unknown status');
  end if;
  update staff set status = p_status where id = p_staff_id;
  return json_build_object('success', true, 'message', 'staff ' || p_status);
end; $$;

create or replace function admin_set_staff_role(p_staff_id uuid, p_role text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if p_role not in ('operator','accountant','manager','admin') then
    return json_build_object('success', false, 'message', 'unknown role');
  end if;
  -- Never leave the group with no admin.
  if p_role <> 'admin'
     and (select role from staff where id = p_staff_id) = 'admin'
     and (select count(*) from staff where role = 'admin' and status = 'approved') <= 1 then
    return json_build_object('success', false, 'message', 'cannot remove the last admin');
  end if;
  update staff set role = p_role where id = p_staff_id;
  return json_build_object('success', true, 'message', 'role updated');
end; $$;

create or replace function admin_set_staff_station(p_staff_id uuid, p_station_id uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  update staff set station_id = p_station_id where id = p_staff_id;
  return json_build_object('success', true, 'message', 'branch assigned');
end; $$;

create or replace function admin_record_delivery(p_tank_id uuid, p_liters numeric)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if not (p_liters > 0) then return json_build_object('success', false, 'message', 'litres must be positive'); end if;
  if (select current_liters + p_liters > capacity_liters from tanks where id = p_tank_id) then
    return json_build_object('success', false, 'message', 'delivery exceeds tank capacity');
  end if;
  update tanks set current_liters = current_liters + p_liters where id = p_tank_id;
  return json_build_object('success', true, 'message', 'delivery recorded');
end; $$;

create or replace function admin_add_credit_customer(
  p_station_id uuid, p_name text, p_phone text default null,
  p_plate text default null, p_limit numeric default 0)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  insert into credit_customers (station_id, name, phone, plate_no, credit_limit, balance)
  values (p_station_id, p_name, p_phone, p_plate, coalesce(p_limit, 0), 0);
  return json_build_object('success', true, 'message', 'customer added');
end; $$;

create or replace function admin_credit_payment(p_customer_id uuid, p_amount numeric)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if not (p_amount > 0) then return json_build_object('success', false, 'message', 'amount must be positive'); end if;
  update credit_customers set balance = greatest(0, balance - p_amount) where id = p_customer_id;
  return json_build_object('success', true, 'message', 'payment recorded');
end; $$;

create or replace function admin_add_expense(
  p_station_id uuid, p_category text, p_amount numeric, p_description text default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  insert into expenses (station_id, category, description, amount_etb)
  values (p_station_id, p_category, p_description, p_amount);
  return json_build_object('success', true, 'message', 'expense added');
end; $$;

create or replace function admin_void_sale(p_sale_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare s sales;
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  select * into s from sales where id = p_sale_id;
  if s.id is null then return json_build_object('success', false, 'message', 'sale not found'); end if;
  if s.voided then return json_build_object('success', false, 'message', 'already voided'); end if;

  update sales set voided = true where id = p_sale_id;

  -- Put the fuel back and reverse any credit.
  update tanks set current_liters = current_liters + s.liters
  where station_id = s.station_id and fuel_type = s.fuel_type
    and id = (select id from tanks where station_id = s.station_id
              and fuel_type = s.fuel_type order by current_liters limit 1);

  if s.payment_method = 'credit' and s.credit_customer_id is not null then
    update credit_customers set balance = greatest(0, balance - s.total_etb)
    where id = s.credit_customer_id;
  end if;

  return json_build_object('success', true, 'message', 'sale voided');
end; $$;

commit;
