-- The schema as it stands after 0001-0006, rebuilt directly rather than
-- migrated, so the later migrations can be run against something real.
--
-- station_id is NULLABLE everywhere, because that is what 0002 actually does:
--
--   alter table %I add column if not exists station_id uuid references stations(id)
--
-- This file used to declare it NOT NULL. A fixture stricter than production
-- does not catch bugs, it hides them - and it hid one: a staff member with no
-- branch could write a shift and an attendance row with no branch, which the
-- manager's page then dropped on an inner join. Against this fixture that
-- insert raised instead, so the fault was invisible until 0015 went looking.

create schema if not exists auth;
create table auth.users (id uuid primary key, email text);
-- Stands in for Supabase's auth.uid(), driven by a session setting.
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.uid', true), '')::uuid
$$;

create table stations (
  id uuid primary key default gen_random_uuid(),
  name text not null unique, town text,
  created_at timestamptz not null default now());

create table staff (
  id uuid primary key default gen_random_uuid(),
  full_name text, username text, password_hash text,
  auth_user_id uuid unique references auth.users(id) on delete set null,
  email text, phone text,
  role text default 'operator', status text default 'pending',
  station_id uuid references stations(id),
  created_at timestamptz not null default now());

create table tanks (
  id serial primary key,
  station_id uuid references stations(id),
  tank_name text, fuel_type text,
  capacity_liters numeric, current_liters numeric);

create table credit_customers (
  id uuid primary key default gen_random_uuid(),
  station_id uuid references stations(id),
  name text, phone text, plate_no text,
  credit_limit numeric default 0, balance numeric default 0);

create table sales (
  id uuid primary key default gen_random_uuid(),
  station_id uuid references stations(id),
  staff_id uuid references staff(id),
  fuel_type text, liters numeric, total_etb numeric,
  payment_method text, credit_customer_id uuid references credit_customers(id),
  voided boolean default false,
  created_at timestamptz not null default now());

create table fuel_prices (
  id uuid primary key default gen_random_uuid(),
  station_id uuid references stations(id),
  fuel_type text, price_per_liter numeric);
create unique index fuel_prices_station_fuel_key on fuel_prices (station_id, fuel_type);

create table shifts (
  id uuid primary key default gen_random_uuid(),
  station_id uuid references stations(id),
  staff_id uuid references staff(id),
  opening_meter numeric, closing_meter numeric,
  opened_at timestamptz, closed_at timestamptz);

create table attendance (
  id uuid primary key default gen_random_uuid(),
  station_id uuid references stations(id),
  staff_id uuid references staff(id),
  check_in timestamptz, check_out timestamptz);

create table expenses (
  id uuid primary key default gen_random_uuid(),
  station_id uuid references stations(id),
  category text, description text, amount_etb numeric,
  created_at timestamptz not null default now());

create table deliveries (
  id uuid primary key default gen_random_uuid(),
  station_id uuid references stations(id),
  tank_id int references tanks(id),
  liters numeric, note text, recorded_by uuid references staff(id),
  created_at timestamptz not null default now());

create table price_history (
  id uuid primary key default gen_random_uuid(),
  station_id uuid references stations(id),
  fuel_type text not null, old_price numeric, new_price numeric not null,
  changed_by uuid references staff(id),
  changed_at timestamptz not null default now());

-- from 0001
create or replace function current_staff() returns staff
language sql stable security definer set search_path = public as $$
  select * from staff where auth_user_id = auth.uid() limit 1;
$$;
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' and status = 'approved' from current_staff()), false);
$$;
create or replace function current_station() returns uuid
language sql stable security definer set search_path = public as $$
  select station_id from current_staff();
$$;

-- from 0004, with the UTC boundary this exercise is about
create or replace function admin_dashboard()
returns table (station_id uuid, station_name text, town text,
  sales_today_etb numeric, liters_today numeric, stock_liters numeric,
  capacity_liters numeric, credit_etb numeric, on_duty int, low_tanks int)
language sql stable security definer set search_path = public as $$
  select st.id, st.name, st.town,
    coalesce((select sum(s.total_etb) from sales s
              where s.station_id = st.id and not coalesce(s.voided,false)
                and s.created_at >= date_trunc('day', now())), 0),
    coalesce((select sum(s.liters) from sales s
              where s.station_id = st.id and not coalesce(s.voided,false)
                and s.created_at >= date_trunc('day', now())), 0),
    coalesce((select sum(t.current_liters)  from tanks t where t.station_id = st.id), 0),
    coalesce((select sum(t.capacity_liters) from tanks t where t.station_id = st.id), 0),
    coalesce((select sum(c.balance) from credit_customers c where c.station_id = st.id), 0),
    coalesce((select count(*)::int from attendance a
              where a.station_id = st.id and a.check_out is null), 0),
    coalesce((select count(*)::int from tanks t
              where t.station_id = st.id and t.capacity_liters > 0
                and (t.current_liters / t.capacity_liters) < 0.30), 0)
  from stations st where is_admin() or st.id = current_station() order by st.name;
$$;

create or replace function my_sales_today()
returns table (id uuid, fuel_type text, liters numeric, total_etb numeric,
               payment_method text, voided boolean, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select s.id, s.fuel_type, s.liters, s.total_etb, s.payment_method,
         coalesce(s.voided,false), s.created_at
  from sales s
  where s.staff_id = (select id from current_staff())
    and s.created_at >= date_trunc('day', now())
  order by s.created_at desc;
$$;
