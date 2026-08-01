-- MAGPMS — build the whole system on a brand-new Supabase project
-- ============================================================================
--
-- ONE paste. Creates every table, every function, the five branches and their
-- tanks, then locks the database down. Nothing else to run afterwards.
--
-- ----------------------------------------------------------------------------
-- WHEN TO USE THIS
-- ----------------------------------------------------------------------------
--   fresh_install.sql   a NEW, EMPTY project        <- this file
--   install_all.sql     a project that already has the original app's tables
--
-- Running this on a database that already holds data is safe - every create is
-- `if not exists` and every seed checks first - but it is not what it is for.
--
-- ----------------------------------------------------------------------------
-- BEFORE YOU PRESS RUN
-- ----------------------------------------------------------------------------
-- Check the project ref in the address bar and make sure it matches the one in
-- config.js. A whole night was lost to running SQL against the wrong project:
-- two Supabase accounts, four projects, and every error that followed was that
-- one mistake wearing a different mask.
--
-- After this finishes, the last lines print what was built. Read them.
-- ============================================================================

-- Supabase ships an `extensions` schema; a plain Postgres does not. Creating it
-- when absent costs nothing and lets this file be tested somewhere other than
-- the database it is meant for - which is the only way to know it works.
create schema if not exists extensions;

set search_path = public, extensions;

create extension if not exists pgcrypto with schema extensions;

-- ----------------------------------------------------------------------------
-- base tables
-- ----------------------------------------------------------------------------
-- These came with the original app rather than from any migration, so a new
-- project has none of them. Shapes match what the functions expect: tanks.id is
-- integer, everything else uuid.

create table if not exists staff (
  id            uuid primary key default gen_random_uuid(),
  full_name     text,
  username      text,
  phone         text,
  email         text,
  role          text default 'operator',
  status        text default 'pending',
  created_at    timestamptz not null default now());

create table if not exists tanks (
  id              serial primary key,
  tank_name       text,
  fuel_type       text,
  capacity_liters numeric,
  current_liters  numeric default 0);

create table if not exists credit_customers (
  id           uuid primary key default gen_random_uuid(),
  name         text,
  phone        text,
  plate_no     text,
  credit_limit numeric default 0,
  balance      numeric default 0);

create table if not exists sales (
  id                 uuid primary key default gen_random_uuid(),
  staff_id           uuid references staff(id),
  fuel_type          text,
  liters             numeric,
  total_etb          numeric,
  payment_method     text,
  credit_customer_id uuid references credit_customers(id),
  voided             boolean default false,
  created_at         timestamptz not null default now());

create table if not exists fuel_prices (
  id              uuid primary key default gen_random_uuid(),
  fuel_type       text,
  price_per_liter numeric);

create table if not exists shifts (
  id            uuid primary key default gen_random_uuid(),
  staff_id      uuid references staff(id),
  opening_meter numeric,
  closing_meter numeric,
  opened_at     timestamptz,
  closed_at     timestamptz);

create table if not exists attendance (
  id        uuid primary key default gen_random_uuid(),
  staff_id  uuid references staff(id),
  check_in  timestamptz,
  check_out timestamptz);

create table if not exists expenses (
  id          uuid primary key default gen_random_uuid(),
  category    text,
  description text,
  amount_etb  numeric,
  created_at  timestamptz not null default now());

create table if not exists deliveries (
  id          uuid primary key default gen_random_uuid(),
  tank_id     int references tanks(id),
  liters      numeric,
  note        text,
  recorded_by uuid references staff(id),
  created_at  timestamptz not null default now());



-- ############################################################################
-- 0001_identity.sql
-- ############################################################################

-- 0001 — one identity, from Supabase Auth
--
-- Written to adapt to the live schema rather than assume it. Every statement
-- is guarded, so this is safe to run twice and will not fail on a column that
-- already exists.
--
-- WHAT CHANGES
--   The database has two credential tables, `admins` and `staff`, each with
--   username + password_hash. The app cannot express "this caller is an
--   admin" against that: PostgREST authenticates every request as the same
--   anon role, so no function can tell who is calling. Identity moves to
--   Supabase Auth, and `staff` becomes the single table, with admins as rows
--   where role = 'admin'.
--
--   `admins` is NOT dropped. It is left in place, unused, so nothing is lost
--   if this needs revisiting. Drop it yourself once you are satisfied.

begin;

-- ---------------------------------------------------------------
-- 1. staff gains the columns the app needs, if it lacks them
-- ---------------------------------------------------------------
alter table staff add column if not exists auth_user_id uuid unique references auth.users(id) on delete set null;
alter table staff add column if not exists email  text;
alter table staff add column if not exists phone  text;
alter table staff add column if not exists role   text;
alter table staff add column if not exists status text;

-- Existing rows may predate these columns.
update staff set role   = 'operator' where role   is null;
update staff set status = 'approved' where status is null;

alter table staff alter column role   set default 'operator';
alter table staff alter column status set default 'pending';

create index if not exists staff_auth_user_id_idx on staff (auth_user_id);

-- ---------------------------------------------------------------
-- 2. fold admins into staff
-- ---------------------------------------------------------------
-- Matched on username, which both tables carry. An admin whose username is
-- already a staff row is promoted rather than duplicated.
do $$
begin
  if to_regclass('public.admins') is null then
    raise notice 'no admins table - nothing to merge';
    return;
  end if;

  update staff s
     set role = 'admin', status = 'approved'
    from admins a
   where a.username = s.username;

  /* password_hash is carried across only if it is still there. 0009 drops it,
     and a static reference to it would make this file fail the second time it
     is run on a database that has been all the way through. A migration you
     cannot re-run is one you have to remember the state of. */
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'staff'
                and column_name = 'password_hash') then
    execute $q$
      insert into staff (id, full_name, username, password_hash, role, status, created_at)
      select a.id, a.full_name, a.username, a.password_hash, 'admin', 'approved', a.created_at
        from admins a
       where not exists (select 1 from staff s where s.username = a.username)
    $q$;
  else
    execute $q$
      insert into staff (id, full_name, username, role, status, created_at)
      select a.id, a.full_name, a.username, 'admin', 'approved', a.created_at
        from admins a
       where not exists (select 1 from staff s where s.username = a.username)
    $q$;
  end if;

  raise notice 'admins merged into staff';
end $$;

-- ---------------------------------------------------------------
-- 3. helper functions - the only place identity is decided
-- ---------------------------------------------------------------
create or replace function current_staff()
returns staff
language sql stable security definer set search_path = public
as $$
  select * from staff where auth_user_id = auth.uid() limit 1;
$$;

create or replace function is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select role = 'admin' and status = 'approved' from current_staff()), false);
$$;

-- current_station() is NOT created here. It reads staff.station_id, and that
-- column does not exist until 0002 adds it - Postgres validates a SQL function
-- body when the function is created, so defining it now fails outright on a
-- database that has not been through 0002 yet. It is created there instead,
-- once the column it depends on is real.

commit;

-- ===============================================================
-- AFTER RUNNING THIS, BEFORE 0002
-- ===============================================================
-- Every person needs an auth.users row, and staff.auth_user_id must point at
-- it. Existing password_hash values cannot be carried across - Supabase Auth
-- hashes differently - so each person sets a password once.
--
-- Run this in a terminal, NOT in the SQL editor. It needs the service_role
-- key, which must never appear in client code or be pasted into a chat.
--
--   // create-auth-users.mjs
--   import { createClient } from "@supabase/supabase-js";
--   const db = createClient(
--     "https://fendopitdcyoefpxuevd.supabase.co",
--     process.env.SERVICE_ROLE_KEY               // export it, do not inline it
--   );
--
--   const { data: staff } = await db.from("staff").select("id, username, email");
--   for (const s of staff) {
--     const email = s.email ?? `${s.username}@magpms.local`;   // placeholder domain
--     const { data, error } = await db.auth.admin.createUser({
--       email,
--       password: "ChangeMe#2026",                             // reset on first login
--       email_confirm: true
--     });
--     if (error) { console.log(s.username, error.message); continue; }
--     await db.from("staff").update({ auth_user_id: data.user.id, email }).eq("id", s.id);
--     console.log("linked", s.username, "->", email);
--   }
--
-- Then verify none were missed:
--   select username, role, auth_user_id is null as unlinked from staff order by unlinked desc;
--
-- A staff row with auth_user_id null cannot sign in - current_staff() returns
-- nothing for them.

-- ############################################################################
-- 0002_stations.sql
-- ############################################################################

-- 0002 — five branches
--
-- Adds station_id to every table that holds branch-specific data. The list is
-- driven by a loop over table names, and each one is checked for existence
-- first, so a table that was renamed or never created is skipped with a notice
-- rather than aborting the migration.
--
-- Layout, from the operator: 5 sites, every site identical —
--   4 tanks of 50,000 L = 200,000 L per branch, 1,000,000 L across the group.
--   1 tank benzil, 3 tanks diesel.

begin;

create table if not exists stations (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  town       text,
  created_at timestamptz not null default now()
);

insert into stations (name, town) values
  ('Adama',     'Adama, East Shewa'),
  ('Dire Dawa', 'Dire Dawa'),
  ('Hirna',     'Hirna, West Hararghe'),
  ('Woleciti',  'Woleciti, East Shewa'),
  ('Heromaya',  'Heromaya, East Hararghe')
on conflict (name) do nothing;

-- ---------------------------------------------------------------
-- station_id everywhere it belongs
-- ---------------------------------------------------------------
do $$
declare
  t text;
  branch_tables text[] := array[
    'staff','tanks','sales','fuel_prices','credit_customers',
    'shifts','attendance','expenses','deliveries',
    'pumps','nozzles','nozzle_readings'
  ];
begin
  foreach t in array branch_tables loop
    if to_regclass('public.' || t) is null then
      raise notice 'skipping %, table not present', t;
      continue;
    end if;
    execute format(
      'alter table %I add column if not exists station_id uuid references stations(id)', t);
  end loop;
end $$;

-- ---------------------------------------------------------------
-- everything that exists today belongs to the original branch
-- ---------------------------------------------------------------
do $$
declare
  t text;
  v_first uuid := (select id from stations where name = 'Hirna');
  branch_tables text[] := array[
    'tanks','sales','fuel_prices','credit_customers',
    'shifts','attendance','expenses','deliveries',
    'pumps','nozzles','nozzle_readings'
  ];
begin
  foreach t in array branch_tables loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('update %I set station_id = %L where station_id is null', t, v_first);
  end loop;

  -- staff is deliberately separate: null station_id means the central admin,
  -- who is not tied to a branch. Only non-admins get backfilled.
  update staff set station_id = v_first
   where station_id is null and coalesce(role, 'operator') <> 'admin';
end $$;

-- Tighten once backfilled. staff stays nullable, for the reason above.
do $$
declare
  t text;
  branch_tables text[] := array[
    'tanks','sales','fuel_prices','credit_customers',
    'shifts','attendance','expenses','deliveries',
    'pumps','nozzles','nozzle_readings'
  ];
begin
  foreach t in array branch_tables loop
    if to_regclass('public.' || t) is null then continue; end if;
    execute format('alter table %I alter column station_id set not null', t);
  end loop;
end $$;

-- ---------------------------------------------------------------
-- current_station(), now that staff.station_id exists
-- ---------------------------------------------------------------
-- Held back from 0001 on purpose: a SQL function body is validated when the
-- function is created, so this could not be written before the column it reads.
-- Null for the central admin, who is not tied to a branch.
create or replace function current_station()
returns uuid
language sql stable security definer set search_path = public
as $$
  select station_id from current_staff();
$$;

-- ---------------------------------------------------------------
-- prices are per branch now
-- ---------------------------------------------------------------
-- Before this, one row per fuel type meant setting the diesel price changed
-- it at every site at once. The old unique constraint on fuel_type alone has
-- to go, whatever it was named.
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.fuel_prices'::regclass
       and contype in ('u','p')
       and pg_get_constraintdef(oid) ilike '%(fuel_type)%'
  loop
    execute format('alter table fuel_prices drop constraint %I', c.conname);
    raise notice 'dropped old constraint % on fuel_prices', c.conname;
  end loop;
end $$;

create unique index if not exists fuel_prices_station_fuel_key
  on fuel_prices (station_id, fuel_type);

-- ---------------------------------------------------------------
-- indexes for the reads the dashboard does constantly
-- ---------------------------------------------------------------
do $$
begin
  if to_regclass('public.sales') is not null then
    execute 'create index if not exists sales_station_created_idx on sales (station_id, created_at desc)';
  end if;
  if to_regclass('public.shifts') is not null then
    execute 'create index if not exists shifts_station_idx on shifts (station_id)';
  end if;
  if to_regclass('public.attendance') is not null then
    execute 'create index if not exists attendance_station_idx on attendance (station_id)';
  end if;
  if to_regclass('public.tanks') is not null then
    execute 'create index if not exists tanks_station_idx on tanks (station_id)';
  end if;
  if to_regclass('public.credit_customers') is not null then
    execute 'create index if not exists credit_customers_station_idx on credit_customers (station_id)';
  end if;
end $$;

commit;

-- ---------------------------------------------------------------
-- tank layout: 4 x 50,000 L per branch, 1 benzil + 3 diesel
-- ---------------------------------------------------------------
-- Only creates tanks for branches that have none, so re-running is harmless
-- and the original branch keeps whatever it already has.
do $$
declare
  s record;
  v_fuel text;
begin
  for s in select id, name from stations loop
    if exists (select 1 from tanks where station_id = s.id) then
      raise notice 'skipping %, already has tanks', s.name;
      continue;
    end if;
    for i in 1..4 loop
      v_fuel := case when i = 1 then 'Benzil' else 'Diesel' end;
      insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
      values (s.id, 'Tank ' || i, v_fuel, 50000, 0);
    end loop;
    raise notice 'seeded 4 tanks for %', s.name;
  end loop;
end $$;

-- If the insert above fails on a column name, check what tanks actually has:
--   select column_name, data_type from information_schema.columns
--   where table_schema='public' and table_name='tanks' order by ordinal_position;
-- and adjust tank_name / fuel_type / capacity_liters / current_liters to match.

-- ############################################################################
-- 0003_price_history.sql
-- ############################################################################

-- 0003 — price history
--
-- The old admin_set_price(uuid, text, numeric) upserted in place, so every
-- previous price was overwritten and unrecoverable. There is no way to answer
-- "what did we charge on the 4th?" after the fact. This adds an append-only
-- trail against fuel_prices.

begin;

create table if not exists price_history (
  id          uuid primary key default gen_random_uuid(),
  station_id  uuid not null references stations(id),
  fuel_type   text not null,
  old_price   numeric,                      -- null on the first ever set
  new_price   numeric not null,
  changed_by  uuid references staff(id),    -- nullable: seeded rows have no author
  changed_at  timestamptz not null default now()
);

create index if not exists price_history_lookup_idx
  on price_history (station_id, fuel_type, changed_at desc);

-- Append-only: a wrong price is corrected by a new row, never by editing an
-- old one. An audit trail you can rewrite is not an audit trail.
revoke update, delete on price_history from authenticated, anon;

commit;

-- ---------------------------------------------------------------
-- seed the trail from whatever fuel_prices holds today
-- ---------------------------------------------------------------
-- So the history does not start empty and the first real change has something
-- to compare against. The price column name is discovered rather than assumed.
do $$
declare
  v_col text;
  v_admin uuid := (select id from staff where role = 'admin' order by created_at limit 1);
begin
  select column_name into v_col
    from information_schema.columns
   where table_schema = 'public' and table_name = 'fuel_prices'
     and column_name in ('price_per_liter','price','price_etb','unit_price')
   order by case column_name
              when 'price_per_liter' then 1 when 'price' then 2
              when 'price_etb' then 3 else 4 end
   limit 1;

  if v_col is null then
    raise notice 'could not find a price column on fuel_prices - seed skipped';
    return;
  end if;

  execute format($f$
    insert into price_history (station_id, fuel_type, old_price, new_price, changed_by)
    select p.station_id, p.fuel_type, null, p.%I, %L
      from fuel_prices p
     where not exists (
       select 1 from price_history h
        where h.station_id = p.station_id and h.fuel_type = p.fuel_type)
  $f$, v_col, v_admin);

  raise notice 'seeded price_history from fuel_prices.%', v_col;
end $$;

-- ---------------------------------------------------------------
-- RELATED BUG, worth fixing while you are here
-- ---------------------------------------------------------------
-- If sales join to fuel_prices at read time, every past receipt silently
-- re-prices whenever the pump price changes. Sales should store the price
-- they were sold at:
--
--   alter table sales add column if not exists price_per_liter numeric;
--   update sales set price_per_liter = round(total_etb / nullif(liters,0), 2)
--    where price_per_liter is null and liters > 0;
--
-- Left commented because it depends on sales having total_etb and liters
-- under those names - check before running.

-- ############################################################################
-- 0004_rpcs.sql
-- ############################################################################

-- 0004 — the functions the pages call
--
-- Two rules hold everywhere below:
--
--   1. No function takes the caller's id. Identity comes from current_staff().
--      The old signatures all led with one - record_sale_v2(uuid, ...),
--      open_shift(uuid, numeric), admin_set_price(uuid, ...) - read from
--      localStorage by the client. Any caller could send any id, so the
--      database had no way to know who was acting. That is what this removes.
--
--   2. p_station_id is a FILTER, never a grant. An admin may narrow to one
--      branch; everyone else is pinned to their own whatever they pass.
--
-- The old functions are dropped by signature at the end, once the new ones
-- exist, so nothing is left callable that still trusts a client-supplied id.

begin;

-- ---------------------------------------------------------------
-- fail fast if the column names differ from what these functions use
-- ---------------------------------------------------------------
do $$
declare
  missing text := '';
  procedure_note text := 'adjust the function bodies below to match, then re-run';
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='fuel_prices'
                    and column_name='price_per_liter') then
    missing := missing || E'\n  fuel_prices.price_per_liter';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='tanks'
                    and column_name='current_liters') then
    missing := missing || E'\n  tanks.current_liters';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='sales'
                    and column_name='total_etb') then
    missing := missing || E'\n  sales.total_etb';
  end if;

  if missing <> '' then
    raise exception E'These columns are not what 0004 expects:%s\n\n%s\n\nList the real ones with:\n  select table_name, column_name from information_schema.columns\n  where table_schema=''public'' and table_name in (''fuel_prices'',''tanks'',''sales'')\n  order by table_name, ordinal_position;',
      missing, procedure_note;
  end if;
end $$;

-- ---------------------------------------------------------------
-- reference
-- ---------------------------------------------------------------
create or replace function me()
returns table (id uuid, full_name text, email text, phone text,
               role text, status text, station_id uuid, station_name text)
language sql stable security definer set search_path = public
as $$
  select s.id, s.full_name, s.email, s.phone, s.role, s.status,
         s.station_id, st.name
  from current_staff() s
  left join stations st on st.id = s.station_id;
$$;

create or replace function register_staff(p_full_name text, p_phone text default null)
returns json
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return json_build_object('success', false, 'message', 'not authenticated');
  end if;
  if exists (select 1 from staff where auth_user_id = v_uid) then
    return json_build_object('success', false, 'message', 'account already registered');
  end if;

  insert into staff (auth_user_id, full_name, phone, email, role, status)
  values (v_uid, p_full_name, p_phone,
          (select email from auth.users where id = v_uid), 'operator', 'pending');

  return json_build_object('success', true, 'message', 'awaiting admin approval');
end;
$$;

create or replace function list_stations()
returns table (id uuid, name text, town text)
language sql stable security definer set search_path = public
as $$
  select s.id, s.name, s.town from stations s
  where is_admin() or s.id = current_station()
  order by s.name;
$$;

-- ---------------------------------------------------------------
-- dashboard: one row per branch, one call for the whole rail
-- ---------------------------------------------------------------
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
  from stations st
  where is_admin() or st.id = current_station()
  order by st.name;
$$;

-- ---------------------------------------------------------------
-- scoped reads
-- ---------------------------------------------------------------
create or replace function get_prices(p_station_id uuid default null)
returns table (fuel_type text, price_per_liter numeric)
language sql stable security definer set search_path = public
as $$
  select p.fuel_type, p.price_per_liter
  from fuel_prices p
  where p.station_id = case when is_admin() then coalesce(p_station_id, p.station_id)
                            else current_station() end
  order by p.fuel_type;
$$;

-- tanks.id is integer here, not uuid - the old admin_record_delivery took
-- (uuid, int, numeric, text), which is what gives that away.
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

-- ---------------------------------------------------------------
-- the caller's own rows
-- ---------------------------------------------------------------
create or replace function my_sales_today()
returns table (id uuid, fuel_type text, liters numeric, total_etb numeric,
               payment_method text, voided boolean, created_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select s.id, s.fuel_type, s.liters, s.total_etb, s.payment_method,
         coalesce(s.voided,false), s.created_at
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

-- ---------------------------------------------------------------
-- staff writes
-- ---------------------------------------------------------------
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
  v_tank int;
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
  from fuel_prices where station_id = v_station and fuel_type = p_fuel_type;
  if v_price is null then
    return json_build_object('success', false, 'message', 'no price set for ' || p_fuel_type);
  end if;

  -- credit customers belong to one branch
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
                     payment_method, credit_customer_id)
  values (v_station, v_staff.id, p_fuel_type, p_liters, round(p_liters * v_price, 2),
          p_payment, p_credit_customer_id);

  update tanks set current_liters = current_liters - p_liters where id = v_tank;

  if p_payment = 'credit' then
    update credit_customers set balance = balance + round(p_liters * v_price, 2)
    where id = p_credit_customer_id;
  end if;

  return json_build_object('success', true, 'message', 'sale recorded');
end;
$$;

create or replace function open_shift(p_opening_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff();
begin
  if v_staff.id is null then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if exists (select 1 from shifts where staff_id = v_staff.id and closed_at is null) then
    return json_build_object('success', false, 'message', 'a shift is already open');
  end if;
  insert into shifts (station_id, staff_id, opening_meter, opened_at)
  values (v_staff.station_id, v_staff.id, p_opening_meter, now());
  return json_build_object('success', true, 'message', 'shift opened');
end; $$;

create or replace function close_shift(p_closing_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); v_id uuid;
begin
  select id into v_id from shifts
  where staff_id = v_staff.id and closed_at is null order by opened_at desc limit 1;
  if v_id is null then return json_build_object('success', false, 'message', 'no open shift'); end if;
  update shifts set closing_meter = p_closing_meter, closed_at = now() where id = v_id;
  return json_build_object('success', true, 'message', 'shift closed');
end; $$;

create or replace function check_in()
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff();
begin
  if v_staff.id is null then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if exists (select 1 from attendance where staff_id = v_staff.id and check_out is null) then
    return json_build_object('success', false, 'message', 'already checked in');
  end if;
  insert into attendance (station_id, staff_id, check_in)
  values (v_staff.station_id, v_staff.id, now());
  return json_build_object('success', true, 'message', 'checked in');
end; $$;

create or replace function check_out()
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); v_id uuid;
begin
  select id into v_id from attendance
  where staff_id = v_staff.id and check_out is null order by check_in desc limit 1;
  if v_id is null then return json_build_object('success', false, 'message', 'not checked in'); end if;
  update attendance set check_out = now() where id = v_id;
  return json_build_object('success', true, 'message', 'checked out');
end; $$;

-- ---------------------------------------------------------------
-- admin writes
-- ---------------------------------------------------------------
create or replace function admin_set_price(p_station_id uuid, p_fuel_type text, p_price numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_admin staff := current_staff(); v_old numeric;
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if not (p_price > 0) then return json_build_object('success', false, 'message', 'price must be positive'); end if;

  select price_per_liter into v_old
  from fuel_prices where station_id = p_station_id and fuel_type = p_fuel_type;

  insert into fuel_prices (station_id, fuel_type, price_per_liter)
  values (p_station_id, p_fuel_type, p_price)
  on conflict (station_id, fuel_type)
  do update set price_per_liter = excluded.price_per_liter;

  -- price and history are written together, so the trail cannot miss a change
  insert into price_history (station_id, fuel_type, old_price, new_price, changed_by)
  values (p_station_id, p_fuel_type, v_old, p_price, v_admin.id);

  return json_build_object('success', true, 'message', 'price updated');
end; $$;

create or replace function admin_list_staff()
returns table (id uuid, full_name text, email text, phone text, role text,
               status text, station_id uuid)
language sql stable security definer set search_path = public
as $$
  select s.id, s.full_name, s.email, s.phone, s.role, s.status, s.station_id
  from staff s where is_admin()
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
  -- never leave the group with no admin
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

create or replace function admin_record_delivery(p_tank_id int, p_liters numeric)
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
declare s sales; v_tank int;
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  select * into s from sales where id = p_sale_id;
  if s.id is null then return json_build_object('success', false, 'message', 'sale not found'); end if;
  if coalesce(s.voided,false) then return json_build_object('success', false, 'message', 'already voided'); end if;

  update sales set voided = true where id = p_sale_id;

  -- put the fuel back into the emptiest matching tank at that branch
  select id into v_tank from tanks
  where station_id = s.station_id and fuel_type = s.fuel_type
  order by current_liters limit 1;
  if v_tank is not null then
    update tanks set current_liters = current_liters + s.liters where id = v_tank;
  end if;

  if s.payment_method = 'credit' and s.credit_customer_id is not null then
    update credit_customers set balance = greatest(0, balance - s.total_etb)
    where id = s.credit_customer_id;
  end if;

  return json_build_object('success', true, 'message', 'sale voided');
end; $$;

commit;

-- ---------------------------------------------------------------
-- retire the old signatures
-- ---------------------------------------------------------------
-- Every one of these takes a caller id as its first argument. Leaving them
-- callable would leave the original hole open beside the fix.
--
-- THREE ARE DELIBERATELY ABSENT FROM THIS LIST:
--
--   list_sales(uuid,int)
--   admin_set_price(uuid,text,numeric)
--   admin_add_credit_customer(uuid,text,text,text,numeric)
--
-- Their old and new signatures are identical - the old leading uuid was a
-- caller id, the new one is a station id - so dropping "the old one" by
-- signature drops the new one that was just created a few lines above. That is
-- exactly what happened: the file created them and then deleted them, and the
-- Sales page, the price form and Add Customer all called functions that were
-- not there. `create or replace` has already replaced them; there is nothing
-- left to retire.
drop function if exists login_staff(text,text);
drop function if exists login_admin(text,text);
drop function if exists create_first_admin(text,text,text);
drop function if exists register_staff(text,text,text,text);
drop function if exists admin_list_staff(text);
drop function if exists admin_set_staff_status(uuid,uuid,text);
drop function if exists admin_set_staff_role(uuid,uuid,text);
drop function if exists record_sale(uuid,text,numeric,numeric,text);
drop function if exists record_sale_v2(uuid,text,numeric,text,uuid);
drop function if exists list_tanks();
drop function if exists get_prices();
drop function if exists open_shift(uuid,numeric);
drop function if exists close_shift(uuid,numeric);
drop function if exists my_open_shift(uuid);
drop function if exists admin_record_delivery(uuid,int,numeric,text);
drop function if exists list_credit_customers();
drop function if exists admin_credit_payment(uuid,uuid,numeric);
drop function if exists admin_add_expense(uuid,text,text,numeric);
drop function if exists list_expenses(int);
drop function if exists admin_void_sale(uuid,uuid);
drop function if exists check_in(uuid);
drop function if exists check_out(uuid);
drop function if exists my_attendance_status(uuid);

-- ############################################################################
-- 0005_lockdown.sql
-- ############################################################################

-- 0005 — close the direct table door
--
-- Run this LAST, and do not skip it.
--
-- The functions in 0004 are only a boundary if the tables are not readable
-- directly. The publishable key in config.js is designed to be public, but
-- that is only safe when the database refuses anonymous table access.
-- Without this, anyone with the key can read every row over
-- /rest/v1/<table> regardless of what the functions check.

begin;

do $$
declare
  t text;
  all_tables text[] := array[
    'stations','staff','admins','tanks','sales','fuel_prices',
    'credit_customers','shifts','attendance','expenses','deliveries',
    'pumps','nozzles','nozzle_readings','price_history',
    'app_security_settings','danger_confirm_codes'
  ];
begin
  foreach t in array all_tables loop
    if to_regclass('public.' || t) is null then
      raise notice 'skipping %, table not present', t;
      continue;
    end if;
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

-- No policies are defined on purpose. With RLS on and no policy, every direct
-- read and write is denied, and the SECURITY DEFINER functions - which run as
-- their owner and bypass RLS - become the only way in. That is the intent:
-- one audited path, not a second unguarded one.

revoke all on all tables in schema public from anon, authenticated;
grant execute on all functions in schema public to authenticated;

-- Signup is the one thing an unauthenticated caller must reach.
grant execute on function register_staff(text, text) to anon;

commit;

-- ===============================================================
-- VERIFY
-- ===============================================================
-- 1. Signed out, from a browser console on the live site:
--
--      await fetch(`${SUPABASE_URL}/rest/v1/staff?select=*`,
--        { headers: { apikey: KEY, Authorization: `Bearer ${KEY}` } })
--        .then(r => r.status)
--
--    Expect 401, or an empty array - never a list of staff. Repeat for
--    sales, credit_customers and expenses.
--
-- 2. Signed in as an operator, call admin_set_price. It must return
--    "not authorised" rather than changing a price - is_admin() reads the
--    database, not the request.
--
-- 3. Signed in as an operator at one branch, call list_sales with another
--    branch's p_station_id. It must still return only their own branch.
--    That is the whole point of the station work: the parameter is a filter
--    for admins, never a grant.

-- ############################################################################
-- 0006_delivery_history.sql
-- ############################################################################

-- 0006 — record deliveries, not just their effect
--
-- 0004's admin_record_delivery only adjusted tanks.current_liters. The stock
-- level came out right, but nothing recorded who delivered what, when, or to
-- which tank - and the database already has a `deliveries` table for exactly
-- that. The old signature, admin_record_delivery(uuid, int, numeric, text),
-- took a fourth text argument that was almost certainly a note, which suggests
-- it wrote there.
--
-- This makes the tank update and the delivery record one transaction, the same
-- way admin_set_price and price_history are written together. A stock level
-- that cannot be traced back to a delivery is how discrepancies become
-- arguments.
--
-- The column names on `deliveries` are discovered rather than assumed, so this
-- adapts to whatever shape the table already has.

begin;

-- Make sure the table exists and carries a station, whatever else it has.
do $$
begin
  if to_regclass('public.deliveries') is null then
    create table deliveries (
      id          uuid primary key default gen_random_uuid(),
      station_id  uuid not null references stations(id),
      tank_id     int  not null,
      liters      numeric not null,
      note        text,
      recorded_by uuid references staff(id),
      created_at  timestamptz not null default now()
    );
    raise notice 'created deliveries';
  end if;
end $$;

alter table deliveries add column if not exists station_id  uuid references stations(id);
alter table deliveries add column if not exists recorded_by uuid references staff(id);
alter table deliveries add column if not exists note        text;

create index if not exists deliveries_station_created_idx
  on deliveries (station_id, created_at desc);

commit;

-- ---------------------------------------------------------------
-- the function, built around the columns that are actually there
-- ---------------------------------------------------------------
do $$
declare
  v_qty  text;   -- litres column
  v_tank text;   -- tank reference column
  v_body text;
begin
  select column_name into v_qty from information_schema.columns
   where table_schema='public' and table_name='deliveries'
     and column_name in ('liters','litres','liters_delivered','quantity','amount')
   order by case column_name when 'liters' then 1 when 'litres' then 2 else 3 end
   limit 1;

  select column_name into v_tank from information_schema.columns
   where table_schema='public' and table_name='deliveries'
     and column_name in ('tank_id','tank')
   limit 1;

  if v_qty is null or v_tank is null then
    raise exception
      E'deliveries is missing a quantity or tank column.\nFound neither of the expected names. List them with:\n  select column_name from information_schema.columns\n  where table_schema=''public'' and table_name=''deliveries'';';
  end if;

  v_body := format($f$
    create or replace function admin_record_delivery(
      p_tank_id int, p_liters numeric, p_note text default null)
    returns json
    language plpgsql security definer set search_path = public
    as $body$
    declare
      v_admin staff := current_staff();
      v_station uuid;
    begin
      if not is_admin() then
        return json_build_object('success', false, 'message', 'not authorised');
      end if;
      if not (p_liters > 0) then
        return json_build_object('success', false, 'message', 'litres must be positive');
      end if;

      select station_id into v_station from tanks where id = p_tank_id;
      if v_station is null then
        return json_build_object('success', false, 'message', 'tank not found');
      end if;
      if (select current_liters + p_liters > capacity_liters from tanks where id = p_tank_id) then
        return json_build_object('success', false, 'message', 'delivery exceeds tank capacity');
      end if;

      update tanks set current_liters = current_liters + p_liters where id = p_tank_id;

      insert into deliveries (station_id, %I, %I, note, recorded_by)
      values (v_station, p_tank_id, p_liters, p_note, v_admin.id);

      return json_build_object('success', true, 'message', 'delivery recorded');
    end;
    $body$;
  $f$, v_tank, v_qty);

  execute v_body;
  raise notice 'admin_record_delivery now writes deliveries.% / deliveries.%', v_tank, v_qty;
end $$;

-- ---------------------------------------------------------------
-- read it back
-- ---------------------------------------------------------------
create or replace function list_deliveries(p_station_id uuid default null, p_limit int default 50)
returns table (id uuid, station_id uuid, station_name text, tank_name text,
               fuel_type text, liters numeric, note text,
               recorded_by_name text, created_at timestamptz)
language plpgsql stable security definer set search_path = public
as $$
declare v_qty text; v_tank text;
begin
  select column_name into v_qty from information_schema.columns
   where table_schema='public' and table_name='deliveries'
     and column_name in ('liters','litres','liters_delivered','quantity','amount')
   order by case column_name when 'liters' then 1 when 'litres' then 2 else 3 end limit 1;
  select column_name into v_tank from information_schema.columns
   where table_schema='public' and table_name='deliveries'
     and column_name in ('tank_id','tank') limit 1;

  return query execute format($f$
    select d.id, d.station_id, st.name, t.tank_name, t.fuel_type,
           d.%I, d.note, s.full_name, d.created_at
      from deliveries d
      join stations st on st.id = d.station_id
      left join tanks t on t.id = d.%I
      left join staff s on s.id = d.recorded_by
     where d.station_id = case when is_admin() then coalesce(%L::uuid, d.station_id)
                               else current_station() end
     order by d.created_at desc
     limit %s
  $f$, v_qty, v_tank, p_station_id, greatest(1, least(p_limit, 500)));
end;
$$;

-- The old four-argument version is superseded.
drop function if exists admin_record_delivery(uuid, int, numeric, text);
drop function if exists admin_record_delivery(int, numeric);

-- ############################################################################
-- 0007_shifts_reports.sql
-- ############################################################################

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

-- ############################################################################
-- 0008_local_day.sql
-- ############################################################################

-- 0008 — make "today" mean today here
--
-- THE BUG
--
-- Three functions decide what counts as today with date_trunc('day', now()).
-- Postgres stores timestamptz in UTC, so that is midnight UTC — which is 3am
-- in Ethiopia. Between local midnight and 3am every morning:
--
--   * admin_dashboard's "Sales today" tile still shows YESTERDAY's takings,
--     and keeps adding this morning's sales onto them.
--   * my_sales_today shows a cashier on the early shift somebody else's
--     numbers from the day before, and their own work counts as nothing until
--     3am.
--
-- It is wrong every single day, not on an edge case, and it is wrong in the
-- direction that matters: an owner reading the dashboard at 6am sees a figure
-- that mixes two days.
--
-- 0007's report_sales already grouped by local date, which is why the report
-- and the dashboard tile disagreed. This is the other half of that fix.
--
-- Nothing about the stored data changes. created_at is still timestamptz in
-- UTC, as it should be. Only the boundary used to read it back moves.

begin;

-- ---------------------------------------------------------------
-- one place that knows where the station is
-- ---------------------------------------------------------------
-- The timezone was a string literal repeated in each function, which is how
-- three copies drift apart. If the group ever operates outside Ethiopia, this
-- is the one line to change.
create or replace function app_timezone()
returns text
language sql immutable
as $$ select 'Africa/Addis_Ababa' $$;

-- Local midnight, expressed as the timestamptz to compare created_at against.
-- Read it inside out: now() converted to local wall-clock time, truncated to
-- the start of that day, then read back as an absolute instant.
create or replace function local_day_start()
returns timestamptz
language sql stable
as $$
  select date_trunc('day', now() at time zone app_timezone()) at time zone app_timezone();
$$;

-- ---------------------------------------------------------------
-- the three callers
-- ---------------------------------------------------------------
-- Bodies are otherwise unchanged from 0004; only the day boundary moves.
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
              where s.station_id = st.id and not coalesce(s.voided,false)
                and s.created_at >= local_day_start()), 0),
    coalesce((select sum(s.liters) from sales s
              where s.station_id = st.id and not coalesce(s.voided,false)
                and s.created_at >= local_day_start()), 0),
    coalesce((select sum(t.current_liters)  from tanks t where t.station_id = st.id), 0),
    coalesce((select sum(t.capacity_liters) from tanks t where t.station_id = st.id), 0),
    coalesce((select sum(c.balance) from credit_customers c where c.station_id = st.id), 0),
    coalesce((select count(*)::int from attendance a
              where a.station_id = st.id and a.check_out is null), 0),
    coalesce((select count(*)::int from tanks t
              where t.station_id = st.id and t.capacity_liters > 0
                and (t.current_liters / t.capacity_liters) < 0.30), 0)
  from stations st
  where is_admin() or st.id = current_station()
  order by st.name;
$$;

create or replace function my_sales_today()
returns table (id uuid, fuel_type text, liters numeric, total_etb numeric,
               payment_method text, voided boolean, created_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select s.id, s.fuel_type, s.liters, s.total_etb, s.payment_method,
         coalesce(s.voided,false), s.created_at
  from sales s
  where s.staff_id = (select id from current_staff())
    and s.created_at >= local_day_start()
  order by s.created_at desc;
$$;

-- report_sales gains nothing in behaviour here - it was already grouping in
-- local time - but it stops carrying its own copy of the timezone name.
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
    select coalesce(p_from, (now() at time zone app_timezone())::date - 29) as d_from,
           coalesce(p_to,   (now() at time zone app_timezone())::date)      as d_to
  )
  select (s.created_at at time zone app_timezone())::date,
         s.station_id, st.name, s.fuel_type,
         count(*)::int, sum(s.liters), sum(s.total_etb)
    from sales s
    join stations st on st.id = s.station_id
   cross join bounds b
   where s.station_id = case when is_admin() then coalesce(p_station_id, s.station_id)
                             else current_station() end
     and not coalesce(s.voided, false)
     and (s.created_at at time zone app_timezone())::date between b.d_from and b.d_to
   group by 1, 2, 3, 4
   order by 1 desc, 3, 4;
$$;

commit;

grant execute on function app_timezone()     to authenticated;
grant execute on function local_day_start()  to authenticated;

-- ===============================================================
-- VERIFY
-- ===============================================================
-- 1. The boundary is local midnight, and it is three hours before UTC's:
--
--      select local_day_start(),
--             date_trunc('day', now()) as old_utc_boundary,
--             date_trunc('day', now()) - local_day_start() as difference;
--
--    difference must be 03:00:00. If it is 00:00:00 the server is already on
--    Africa/Addis_Ababa and nothing was broken; if it is anything else, check
--    what app_timezone() returns.
--
-- 2. The dashboard tile and the report now agree for today:
--
--      select sum(sales_today_etb) from admin_dashboard();
--      select sum(sales_etb) from report_sales(
--        null, (now() at time zone app_timezone())::date,
--              (now() at time zone app_timezone())::date);
--
--    These must match. Before this migration they differed for any sale made
--    between local midnight and 3am.
--
-- 3. The clearest proof, if you can run it between midnight and 3am local:
--    record a sale, then check that it appears in the till's "My Day" total.
--    Before this it would not have, until 3am.

-- ############################################################################
-- 0009_drop_password_hash.sql
-- ############################################################################

-- 0009 — remove the old password hashes
--
-- staff.password_hash is left over from the login system this app replaced.
-- Nothing reads it: not one function in 0004 or 0007, not one page. 0001
-- copied it across when folding admins into staff, and it has been dead weight
-- since identity moved to Supabase Auth.
--
-- Dead, but not harmless. These are real password hashes produced by a system
-- whose hashing method was never established - it could be bcrypt, or md5, or
-- nothing at all. People reuse passwords between systems, so if this table ever
-- leaked, the damage would not stop at this app. A column nobody reads is pure
-- liability: it can only ever cost something.
--
-- Current passwords are unaffected. Supabase Auth keeps those as bcrypt in
-- auth.users.encrypted_password, in a different schema this app has never been
-- granted access to.

begin;

-- ---------------------------------------------------------------
-- say what is about to happen, and to how many rows
-- ---------------------------------------------------------------
do $$
declare
  v_total int;
  v_with  int;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'staff'
                    and column_name = 'password_hash') then
    raise notice 'staff.password_hash is already gone - nothing to do';
    return;
  end if;

  select count(*) into v_total from staff;
  execute 'select count(*) from staff where password_hash is not null' into v_with;

  raise notice 'staff rows: %, of which % still carry an old password hash', v_total, v_with;
  if v_with = 0 then
    raise notice 'none left - this drop is tidying, not remediation';
  end if;
end $$;

-- ---------------------------------------------------------------
-- refuse rather than cascade
-- ---------------------------------------------------------------
-- No `cascade`. If a view, index or constraint turns out to depend on this
-- column, Postgres aborts and names it, instead of quietly removing whatever
-- was built on top. An unexpected dependency is information, not an obstacle.
alter table staff drop column if exists password_hash;

commit;

-- ---------------------------------------------------------------
-- tell PostgREST the shape changed
-- ---------------------------------------------------------------
-- Without this, the API keeps serving from a cached picture of the schema
-- taken before the drop, and every RPC fails with
--
--   Could not find the function public.me without parameters in the schema cache
--
-- which reads as "the function is gone" when the function is fine. Supabase
-- reloads automatically on most DDL, but not reliably or immediately, and the
-- window is long enough to lock an admin out of their own dashboard. It costs
-- nothing to be explicit.
notify pgrst, 'reload schema';

-- ---------------------------------------------------------------
-- a note on staff.username, deliberately not dropped
-- ---------------------------------------------------------------
-- username is equally unused - the app matches on auth_user_id and shows
-- full_name - and every remaining row has it null, because rows created
-- through register_staff never set it. It could go the same way.
--
-- It is left alone because it is not credential material. The case for
-- dropping password_hash is that keeping it carries risk; the case for
-- dropping username is only tidiness, and that is a weaker reason to remove
-- a column from a live database. Drop it if you want to:
--
--   alter table staff drop column if exists username;

-- ===============================================================
-- VERIFY
-- ===============================================================
-- 1. The column is gone:
--
--      select column_name from information_schema.columns
--       where table_schema = 'public' and table_name = 'staff'
--       order by ordinal_position;
--
--    Expect no password_hash. auth_user_id, email, phone, role, status and
--    station_id all remain - those are what identity actually runs on.
--
-- 2. Identity still resolves. current_staff() returns the staff composite
--    type, so the type's shape changes with the table. Nothing needs
--    recreating: this was run on Postgres 16 against a copy of this schema,
--    including a plpgsql function holding `declare v_staff staff` that was
--    compiled BEFORE the drop - the shape plpgsql resolves at runtime, so
--    record_sale, open_shift and check_in all keep working untouched.
--    Worth confirming here anyway, since it costs one query:
--
--      select id, full_name, role, status from current_staff();
--      select is_admin();
--
--    Run signed in as yourself. Expect your row, and true.
--
-- 3. The app still works: sign out, sign back in, open the dashboard. If
--    identity had broken, sign-in would fail at me() rather than silently.

-- ============================================================================
-- FINISH
-- ============================================================================
notify pgrst, 'reload schema';

do $report$
declare
  v_stations int; v_tanks int; v_fns int; v_rls int;
begin
  select count(*) into v_stations from stations;
  select count(*) into v_tanks    from tanks;
  select count(*) into v_fns from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('me','current_staff','is_admin','current_station',
                       'admin_dashboard','list_shifts','list_attendance',
                       'report_sales','record_sale','local_day_start');
  select count(*) into v_rls from pg_tables
   where schemaname = 'public' and rowsecurity;

  raise notice '--------------------------------------------------';
  raise notice 'branches ................ % (expect 5)', v_stations;
  raise notice 'tanks ................... % (expect 20)', v_tanks;
  raise notice 'key functions ........... % of 10', v_fns;
  raise notice 'tables with RLS on ...... %', v_rls;
  raise notice '--------------------------------------------------';
  if v_stations = 5 and v_tanks = 20 and v_fns = 10 then
    raise notice 'READY. Next: sign up at the app, then promote yourself to admin.';
  else
    raise notice 'SOMETHING IS MISSING - scroll up for the error that stopped it';
  end if;
end $report$;


-- ============================================================================
-- 0010 - the staff row is created by the database, not the browser
-- ============================================================================
begin;

-- ---------------------------------------------------------------
-- the trigger function
-- ---------------------------------------------------------------
-- The name and phone arrive in raw_user_meta_data, which is what
-- signUp({ options: { data } }) writes. They are whatever the person typed,
-- so treat them as untrusted input: trim them, and turn blank into null
-- rather than storing an empty string that later reads as a name.
create or replace function handle_new_auth_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.staff (auth_user_id, full_name, phone, email, role, status)
  values (new.id,
          nullif(trim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), ''),
          nullif(trim(coalesce(new.raw_user_meta_data ->> 'phone', '')), ''),
          new.email,
          'operator',
          'pending')
  on conflict (auth_user_id) do nothing;

  return new;

-- A trigger on auth.users runs INSIDE Supabase's signup transaction. If it
-- raises, the whole signup is rolled back and the person is told their
-- account could not be created - so a fault here would break the one thing
-- this migration exists to protect. Swallow it, log it, and let the login
-- through: an account with no staff row can be repaired by hand, but an
-- account that was never created cannot be repaired at all.
exception when others then
  raise warning 'handle_new_auth_user: no staff row for % (%)', new.email, sqlerrm;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_auth_user();

-- ---------------------------------------------------------------
-- register_staff, now that it is no longer load-bearing
-- ---------------------------------------------------------------
-- The trigger gets there first, so by the time the browser calls this the row
-- usually exists. The old body answered that with 'account already
-- registered', which was true and unhelpful - it would have shown a first-time
-- signup a message about an account they had just made.
--
-- What it is actually for now is filling in what the trigger could not. The
-- trigger reads the name from metadata; if the app is an older build that
-- does not send metadata, the name arrives here instead. Either way the
-- outcome is the same, so report the same thing.
--
-- coalesce(nullif(...), full_name) means a blank submission never erases a
-- name that is already there.
create or replace function register_staff(p_full_name text, p_phone text default null)
returns json
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return json_build_object('success', false, 'message', 'not authenticated');
  end if;

  update staff
     set full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
         phone     = coalesce(nullif(trim(p_phone), ''), phone)
   where auth_user_id = v_uid;

  if found then
    return json_build_object('success', true, 'message', 'awaiting admin approval');
  end if;

  -- No row yet: an older database without the trigger, or a login created
  -- before this migration ran. Same outcome, reached the long way.
  insert into staff (auth_user_id, full_name, phone, email, role, status)
  values (v_uid,
          nullif(trim(p_full_name), ''),
          nullif(trim(p_phone), ''),
          (select email from auth.users where id = v_uid),
          'operator', 'pending')
  on conflict (auth_user_id) do nothing;

  return json_build_object('success', true, 'message', 'awaiting admin approval');
end $$;

grant execute on function register_staff(text, text) to anon, authenticated;

commit;

-- PostgREST serves from a cached picture of the schema. register_staff kept
-- its signature, so this is belt and braces rather than strictly required -
-- but 0009 taught us what a stale cache looks like from the outside, and it
-- costs nothing.
notify pgrst, 'reload schema';

-- ===============================================================
-- REPAIR: logins that were created before this ran
-- ===============================================================
-- Anyone who signed up while confirmation was on has a login and no staff
-- row. The trigger only fires on new inserts, so it will not go back for
-- them. This does, once:
--
--   insert into public.staff (auth_user_id, full_name, phone, email, role, status)
--   select u.id,
--          nullif(trim(coalesce(u.raw_user_meta_data ->> 'full_name', '')), ''),
--          nullif(trim(coalesce(u.raw_user_meta_data ->> 'phone', '')), ''),
--          u.email, 'operator', 'pending'
--     from auth.users u
--    where not exists (select 1 from public.staff s where s.auth_user_id = u.id)
--   returning full_name, email, role, status;
--
-- full_name will be null for anyone who signed up through a build of the app
-- that did not send metadata. They show in the staff list with a blank name,
-- which is visible and fixable, rather than absent and invisible:
--
--   update public.staff set full_name = 'Their Name' where email = '...';
--
-- ===============================================================
-- VERIFY
-- ===============================================================
-- 1. The trigger is attached:
--
--      select tgname, tgenabled from pg_trigger
--       where tgrelid = 'auth.users'::regclass and not tgisinternal;
--
--    Expect on_auth_user_created, and tgenabled = 'O'.
--
-- 2. Every login has a staff row - this is the invariant the whole migration
--    exists to hold, and it is one query:
--
--      select count(*) as logins_without_staff
--        from auth.users u
--       where not exists (select 1 from public.staff s where s.auth_user_id = u.id);
--
--    Expect 0, now and after every future signup.
--
-- 3. A real signup still works: have someone create an account and check they
--    appear in the staff list as pending, with their name filled in.


-- ============================================================================
-- 0011 - a write that changed nothing is not a success
-- ============================================================================
begin;

-- ---------------------------------------------------------------
-- staff status - the one that was actually caught
-- ---------------------------------------------------------------
create or replace function admin_set_staff_status(p_staff_id uuid, p_status text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if p_status not in ('pending','approved','rejected') then
    return json_build_object('success', false, 'message', 'unknown status');
  end if;

  update staff set status = p_status where id = p_staff_id;
  if not found then
    return json_build_object('success', false, 'message', 'no such staff member');
  end if;

  return json_build_object('success', true, 'message', 'staff ' || p_status);
end; $$;

-- ---------------------------------------------------------------
-- staff role
-- ---------------------------------------------------------------
-- The last-admin guard stays exactly as it was. It reads the row before
-- deciding, so it already fails safe on a bad id - a missing row is not an
-- admin, so the guard passes and the update then matches nothing. That is
-- what the new check catches.
create or replace function admin_set_staff_role(p_staff_id uuid, p_role text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if p_role not in ('operator','accountant','manager','admin') then
    return json_build_object('success', false, 'message', 'unknown role');
  end if;
  if p_role <> 'admin'
     and (select role from staff where id = p_staff_id) = 'admin'
     and (select count(*) from staff where role = 'admin' and status = 'approved') <= 1 then
    return json_build_object('success', false, 'message', 'cannot remove the last admin');
  end if;

  update staff set role = p_role where id = p_staff_id;
  if not found then
    return json_build_object('success', false, 'message', 'no such staff member');
  end if;

  return json_build_object('success', true, 'message', 'role updated');
end; $$;

-- ---------------------------------------------------------------
-- staff branch
-- ---------------------------------------------------------------
-- p_station_id null is legitimate and means "no branch" - that is how a
-- central admin sees all five. So null is not an error here; only a staff id
-- that matches nothing is.
create or replace function admin_set_staff_station(p_staff_id uuid, p_station_id uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;

  if p_station_id is not null
     and not exists (select 1 from stations where id = p_station_id) then
    return json_build_object('success', false, 'message', 'no such branch');
  end if;

  update staff set station_id = p_station_id where id = p_staff_id;
  if not found then
    return json_build_object('success', false, 'message', 'no such staff member');
  end if;

  return json_build_object('success', true,
    'message', case when p_station_id is null then 'branch cleared' else 'branch assigned' end);
end; $$;

-- ---------------------------------------------------------------
-- credit payment
-- ---------------------------------------------------------------
-- Money. A payment recorded against an id that does not exist would report
-- "payment recorded" while the customer's balance stayed exactly where it
-- was - and the next person to look would see a debt the customer believes
-- they have already paid.
create or replace function admin_credit_payment(p_customer_id uuid, p_amount numeric)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if not (p_amount > 0) then return json_build_object('success', false, 'message', 'amount must be positive'); end if;

  update credit_customers set balance = greatest(0, balance - p_amount) where id = p_customer_id;
  if not found then
    return json_build_object('success', false, 'message', 'no such customer');
  end if;

  return json_build_object('success', true, 'message', 'payment recorded');
end; $$;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
-- Signed in as an admin, call one with an id that cannot exist:
--
--   select admin_set_staff_status(
--            '00000000-0000-0000-0000-000000000000'::uuid, 'approved');
--
-- Expect {"success": false, "message": "no such staff member"}.
-- Before this migration the same call returned success.
--
-- Then approve somebody real through the app and confirm it still works:
--
--   select full_name, status from staff order by status, full_name;


-- ============================================================================
-- 0012 - corrections
-- ============================================================================
begin;

-- ---------------------------------------------------------------
-- the record
-- ---------------------------------------------------------------
-- old_liters and old_total are filled in at the moment of fixing, not at the
-- moment of reporting. The sale can be corrected only once, but a report
-- might sit for a day before anyone looks at it, and what matters for the
-- audit trail is what the numbers actually were when they changed.
create table if not exists sale_corrections (
  id             uuid primary key default gen_random_uuid(),
  sale_id        uuid not null references sales(id),
  station_id     uuid references stations(id),
  reported_by    uuid references staff(id),
  reported_at    timestamptz not null default now(),
  reason         text,
  claimed_liters numeric,
  status         text not null default 'open',
  resolved_by    uuid references staff(id),
  resolved_at    timestamptz,
  resolution_note text,
  old_liters     numeric,
  old_total      numeric,
  new_liters     numeric,
  new_total      numeric);

create index if not exists sale_corrections_status_idx
  on sale_corrections (status, reported_at desc);
create index if not exists sale_corrections_station_idx
  on sale_corrections (station_id, reported_at desc);

-- One open report per sale. Without this, a cashier tapping twice creates two
-- reports, an admin fixes both, and the tank is adjusted for the same mistake
-- a second time - which is a worse error than the one being corrected.
create unique index if not exists sale_corrections_one_open_idx
  on sale_corrections (sale_id) where status = 'open';

alter table sale_corrections enable row level security;
revoke all on sale_corrections from anon, authenticated;

-- ---------------------------------------------------------------
-- the cashier reports it
-- ---------------------------------------------------------------
create or replace function report_sale_mistake(
  p_sale_id uuid, p_reason text, p_correct_liters numeric default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  s sales;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if coalesce(trim(p_reason), '') = '' then
    return json_build_object('success', false, 'message', 'say what went wrong');
  end if;

  select * into s from sales where id = p_sale_id;
  if s.id is null then
    return json_build_object('success', false, 'message', 'sale not found');
  end if;

  -- Own sales only. Not a matter of trust: a cashier reporting somebody
  -- else's sale is describing something they did not see.
  if s.staff_id is distinct from v_staff.id then
    return json_build_object('success', false, 'message', 'that is not your sale');
  end if;
  if coalesce(s.voided, false) then
    return json_build_object('success', false, 'message', 'that sale was already voided');
  end if;
  if exists (select 1 from sale_corrections
              where sale_id = p_sale_id and status = 'open') then
    return json_build_object('success', false, 'message', 'already reported - the manager has it');
  end if;
  if p_correct_liters is not null and p_correct_liters <= 0 then
    return json_build_object('success', false, 'message', 'litres must be more than zero');
  end if;

  insert into sale_corrections (sale_id, station_id, reported_by, reason, claimed_liters)
  values (p_sale_id, s.station_id, v_staff.id, trim(p_reason), p_correct_liters);

  return json_build_object('success', true, 'message', 'reported - the manager will review it');
end; $$;

-- ---------------------------------------------------------------
-- what the cashier can see afterwards
-- ---------------------------------------------------------------
-- Being able to see that it was received, and what was decided, is most of
-- the point. A report that vanishes is no better than telling someone.
create or replace function my_corrections(p_limit int default 20)
returns table (id uuid, sale_id uuid, reported_at timestamptz, reason text,
               claimed_liters numeric, status text, resolved_at timestamptz,
               resolution_note text, fuel_type text, old_liters numeric,
               new_liters numeric)
language sql stable security definer set search_path = public
as $$
  select c.id, c.sale_id, c.reported_at, c.reason, c.claimed_liters, c.status,
         c.resolved_at, c.resolution_note, s.fuel_type, c.old_liters, c.new_liters
  from sale_corrections c
  join sales s on s.id = c.sale_id
  where c.reported_by = (select id from current_staff())
  order by c.reported_at desc
  limit greatest(1, least(coalesce(p_limit, 20), 200));
$$;

-- ---------------------------------------------------------------
-- what the admin sees
-- ---------------------------------------------------------------
create or replace function admin_list_corrections(
  p_station_id uuid default null, p_status text default 'open', p_limit int default 100)
returns table (id uuid, sale_id uuid, station_id uuid, station_name text,
               staff_name text, reported_at timestamptz, reason text,
               claimed_liters numeric, status text, fuel_type text,
               sale_liters numeric, sale_total numeric, payment_method text,
               sale_at timestamptz, resolved_at timestamptz, resolution_note text,
               old_liters numeric, new_liters numeric)
language sql stable security definer set search_path = public
as $$
  select c.id, c.sale_id, c.station_id, st.name, rep.full_name,
         c.reported_at, c.reason, c.claimed_liters, c.status,
         s.fuel_type, s.liters, s.total_etb, s.payment_method, s.created_at,
         c.resolved_at, c.resolution_note, c.old_liters, c.new_liters
  from sale_corrections c
  join sales s        on s.id = c.sale_id
  left join stations st on st.id = c.station_id
  left join staff rep   on rep.id = c.reported_by
  where is_admin()
    and (p_station_id is null or c.station_id = p_station_id)
    and (p_status is null or p_status = 'all' or c.status = p_status)
  order by c.reported_at desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

-- ---------------------------------------------------------------
-- the admin decides
-- ---------------------------------------------------------------
-- Fixing re-prices at the sale's OWN unit rate, not today's. A sale made
-- yesterday at 95 stays at 95 even if the price moved this morning -
-- correcting a typo must not quietly restate history at a different price.
create or replace function admin_resolve_correction(
  p_correction_id uuid, p_action text,
  p_correct_liters numeric default null, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_admin  staff := current_staff();
  c        sale_corrections;
  s        sales;
  v_liters numeric;
  v_unit   numeric;
  v_total  numeric;
  v_delta  numeric;
  v_tank   int;
  v_stock  numeric;
begin
  if not is_admin() then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if p_action not in ('fix', 'reject') then
    return json_build_object('success', false, 'message', 'unknown action');
  end if;

  select * into c from sale_corrections where id = p_correction_id;
  if c.id is null then
    return json_build_object('success', false, 'message', 'no such report');
  end if;
  if c.status <> 'open' then
    return json_build_object('success', false, 'message', 'already dealt with');
  end if;

  if p_action = 'reject' then
    update sale_corrections
       set status = 'rejected', resolved_by = v_admin.id,
           resolved_at = now(), resolution_note = nullif(trim(p_note), '')
     where id = p_correction_id;
    return json_build_object('success', true, 'message', 'report rejected');
  end if;

  -- ---- fix ----
  v_liters := coalesce(p_correct_liters, c.claimed_liters);
  if v_liters is null or v_liters <= 0 then
    return json_build_object('success', false, 'message', 'enter the correct litres');
  end if;

  select * into s from sales where id = c.sale_id;
  if s.id is null then
    return json_build_object('success', false, 'message', 'sale not found');
  end if;
  if coalesce(s.voided, false) then
    return json_build_object('success', false, 'message', 'that sale has been voided since');
  end if;
  if coalesce(s.liters, 0) <= 0 then
    return json_build_object('success', false, 'message', 'the original sale has no litres to re-price from');
  end if;

  v_unit  := s.total_etb / s.liters;
  v_total := round(v_liters * v_unit, 2);
  v_delta := v_liters - s.liters;          -- positive means MORE fuel left the tank

  -- The tank moves by the difference only. The original sale already took
  -- its litres out; this corrects that movement rather than repeating it.
  --
  -- Which tank depends on the direction, the same way voiding does: take the
  -- extra from the fullest, and put a refund back into the emptiest. Picking
  -- one tank for both would drain a nearly-empty tank, or overfill a full
  -- one, for no reason other than that it happened to sort first.
  if v_delta > 0 then
    select id, current_liters into v_tank, v_stock from tanks
     where station_id = s.station_id and fuel_type = s.fuel_type
     order by current_liters desc limit 1;

    if v_tank is not null and v_stock < v_delta then
      -- Refuse rather than write a negative tank. A tank that cannot have
      -- held the fuel means the corrected figure is wrong, or the stock is.
      return json_build_object('success', false,
        'message', 'the tank does not hold enough for that correction - check the figure');
    end if;
  else
    select id, current_liters into v_tank, v_stock from tanks
     where station_id = s.station_id and fuel_type = s.fuel_type
     order by current_liters asc limit 1;

    if v_tank is not null
       and (select current_liters - v_delta > capacity_liters from tanks where id = v_tank) then
      return json_build_object('success', false,
        'message', 'putting that much back would overfill the tank - check the figure');
    end if;
  end if;

  update sales set liters = v_liters, total_etb = v_total where id = s.id;

  if v_tank is not null then
    update tanks set current_liters = current_liters - v_delta where id = v_tank;
  end if;

  -- Credit follows the money, in the same direction.
  if s.payment_method = 'credit' and s.credit_customer_id is not null then
    update credit_customers
       set balance = greatest(0, balance + (v_total - s.total_etb))
     where id = s.credit_customer_id;
  end if;

  update sale_corrections
     set status = 'fixed', resolved_by = v_admin.id, resolved_at = now(),
         resolution_note = nullif(trim(p_note), ''),
         old_liters = s.liters, old_total = s.total_etb,
         new_liters = v_liters, new_total = v_total
   where id = p_correction_id;

  return json_build_object('success', true, 'message', 'sale corrected');
end; $$;

grant execute on function report_sale_mistake(uuid, text, numeric)          to authenticated;
grant execute on function my_corrections(int)                               to authenticated;
grant execute on function admin_list_corrections(uuid, text, int)           to authenticated;
grant execute on function admin_resolve_correction(uuid, text, numeric, text) to authenticated;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
-- 1. The table and its guard exist:
--
--      select indexname from pg_indexes
--       where tablename = 'sale_corrections';
--
--    Expect sale_corrections_one_open_idx among them - that is what stops
--    the same mistake being corrected twice.
--
-- 2. A cashier can report only their own sale. Signed in as one:
--
--      select report_sale_mistake('<someone-elses-sale>', 'wrong amount');
--
--    Expect {"success": false, "message": "that is not your sale"}.
--
-- 3. After fixing one, the numbers agree. The sale, the tank and the report
--    should tell the same story:
--
--      select old_liters, new_liters, old_total, new_total, status
--        from sale_corrections order by reported_at desc limit 1;


-- ============================================================================
-- 0013 - who sold what
-- ============================================================================
begin;

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

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
-- Signed in as an admin:
--
--   select staff_name, station_name, sale_count, sales_etb, credit_etb,
--          voided_count, days_active
--     from report_staff(null, current_date - 6, current_date);
--
-- One row per person per branch for the last week, biggest seller first.
--
-- The totals must agree with the sales report over the same range:
--
--   select sum(sales_etb) from report_staff(null, current_date - 6, current_date);
--   select sum(sales_etb) from report_sales(null, current_date - 6, current_date);
--
-- Both exclude voided sales, so these two numbers should match. If they do
-- not, a sale has no staff_id against it - which is worth knowing.


-- ============================================================================
-- 0014 - backup
-- ============================================================================
begin;

create or replace function admin_backup()
returns json
language sql stable security definer set search_path = public
as $$
  select case when not is_admin() then
    json_build_object('error', 'not authorised')
  else
    json_build_object(
      'magpms_backup_version', 1,
      'generated_at', now(),
      'timezone', app_timezone(),
      -- Counts first, so the person holding the file can check it against
      -- the app without reading the whole document.
      'counts', json_build_object(
        'stations',         (select count(*) from stations),
        'staff',            (select count(*) from staff),
        'tanks',            (select count(*) from tanks),
        'fuel_prices',      (select count(*) from fuel_prices),
        'sales',            (select count(*) from sales),
        'credit_customers', (select count(*) from credit_customers),
        'expenses',         (select count(*) from expenses),
        'shifts',           (select count(*) from shifts),
        'attendance',       (select count(*) from attendance),
        'deliveries',       (select count(*) from deliveries),
        'price_history',    (select count(*) from price_history),
        'sale_corrections', (select count(*) from sale_corrections)
      ),
      'stations',         coalesce((select json_agg(t) from stations t), '[]'::json),
      -- staff carries email and phone: business data the owner already sees
      -- in the app. password_hash is stripped by name rather than trusted to
      -- be absent. 0009 dropped that column, but a backup is exactly the
      -- wrong place to depend on a migration having run - if the column ever
      -- exists again, on any database this is pointed at, the file must not
      -- carry it out of the building.
      'staff',            coalesce((select jsonb_agg(to_jsonb(t) - 'password_hash')
                                      from staff t), '[]'::jsonb),
      'tanks',            coalesce((select json_agg(t) from tanks t), '[]'::json),
      'fuel_prices',      coalesce((select json_agg(t) from fuel_prices t), '[]'::json),
      'sales',            coalesce((select json_agg(t) from sales t), '[]'::json),
      'credit_customers', coalesce((select json_agg(t) from credit_customers t), '[]'::json),
      'expenses',         coalesce((select json_agg(t) from expenses t), '[]'::json),
      'shifts',           coalesce((select json_agg(t) from shifts t), '[]'::json),
      'attendance',       coalesce((select json_agg(t) from attendance t), '[]'::json),
      'deliveries',       coalesce((select json_agg(t) from deliveries t), '[]'::json),
      'price_history',    coalesce((select json_agg(t) from price_history t), '[]'::json),
      'sale_corrections', coalesce((select json_agg(t) from sale_corrections t), '[]'::json)
    )
  end;
$$;

grant execute on function admin_backup() to authenticated;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
-- Signed in as an admin, the counts should match what the app shows:
--
--   select admin_backup() -> 'counts';
--
-- And as anyone else it must refuse rather than return a partial answer:
--
--   select admin_backup() ->> 'error';       -- expect: not authorised
--
-- ===============================================================
-- RESTORING
-- ===============================================================
-- This file is a record, not a restore button, and it is worth being honest
-- about the difference. Putting it back means inserting the rows again in
-- dependency order - stations, staff, tanks, then everything that references
-- them - and re-linking staff.auth_user_id to accounts that would have to be
-- recreated in Supabase Auth first, because auth.users is not in here and
-- cannot be.
--
-- What it is genuinely good for: proving what the books said on a given day,
-- moving to another project, and answering "what did we sell last March"
-- after something has gone wrong. Keep one a week, off the phone.


-- ============================================================================
-- 0015 - shifts and attendance that survive a forgotten check-out
-- ============================================================================
begin;

alter table attendance add column if not exists abandoned boolean not null default false;
alter table shifts     add column if not exists abandoned boolean not null default false;

create index if not exists attendance_open_idx
  on attendance (staff_id) where check_out is null and not abandoned;
create index if not exists shifts_open_idx
  on shifts (staff_id) where closed_at is null and not abandoned;

-- ---------------------------------------------------------------
-- checking in
-- ---------------------------------------------------------------
create or replace function check_in()
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  v_open  attendance;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;

  -- Refuse rather than write a row the manager will never see. Fault (2).
  if v_staff.station_id is null then
    return json_build_object('success', false,
      'message', 'no branch assigned - ask the manager before checking in');
  end if;

  select * into v_open from attendance
   where staff_id = v_staff.id and check_out is null and not abandoned
   order by check_in desc limit 1;

  if v_open.id is not null then
    if (v_open.check_in at time zone app_timezone())::date
       = (now() at time zone app_timezone())::date then
      return json_build_object('success', false, 'message', 'already checked in today');
    end if;

    -- From a previous day: they went home and forgot. Mark it, do not invent
    -- a time for it, and let today proceed.
    update attendance set abandoned = true where id = v_open.id;
  end if;

  insert into attendance (station_id, staff_id, check_in)
  values (v_staff.station_id, v_staff.id, now());

  return json_build_object('success', true, 'message', 'checked in');
end; $$;

create or replace function check_out()
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); v_id uuid;
begin
  if v_staff.id is null then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;

  select id into v_id from attendance
   where staff_id = v_staff.id and check_out is null and not abandoned
   order by check_in desc limit 1;
  if v_id is null then return json_build_object('success', false, 'message', 'not checked in'); end if;

  update attendance set check_out = now() where id = v_id;
  return json_build_object('success', true, 'message', 'checked out');
end; $$;

create or replace function my_attendance_status()
returns table (id uuid, check_in timestamptz, check_out timestamptz)
language sql stable security definer set search_path = public
as $$
  select a.id, a.check_in, a.check_out
  from attendance a
  where a.staff_id = (select id from current_staff())
    and not a.abandoned
  order by a.check_in desc limit 1;
$$;

-- ---------------------------------------------------------------
-- shifts
-- ---------------------------------------------------------------
create or replace function open_shift(p_opening_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  v_open  shifts;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if v_staff.station_id is null then
    return json_build_object('success', false,
      'message', 'no branch assigned - ask the manager before opening a shift');
  end if;
  if p_opening_meter is null or p_opening_meter < 0 then
    return json_build_object('success', false, 'message', 'enter the opening meter reading');
  end if;

  select * into v_open from shifts
   where staff_id = v_staff.id and closed_at is null and not abandoned
   order by opened_at desc limit 1;

  if v_open.id is not null then
    if (v_open.opened_at at time zone app_timezone())::date
       = (now() at time zone app_timezone())::date then
      return json_build_object('success', false, 'message', 'a shift is already open today');
    end if;

    -- A shift left open overnight can never yield a meter variance: nobody
    -- read the pump when they left. Marking it abandoned says exactly that,
    -- where inventing a closing meter would put a false variance into the
    -- one column that exists to catch missing fuel.
    update shifts set abandoned = true where id = v_open.id;
  end if;

  insert into shifts (station_id, staff_id, opening_meter, opened_at)
  values (v_staff.station_id, v_staff.id, p_opening_meter, now());

  return json_build_object('success', true, 'message', 'shift opened');
end; $$;

create or replace function close_shift(p_closing_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); v_id uuid; v_open numeric;
begin
  if v_staff.id is null then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if p_closing_meter is null or p_closing_meter < 0 then
    return json_build_object('success', false, 'message', 'enter the closing meter reading');
  end if;

  select id, opening_meter into v_id, v_open from shifts
   where staff_id = v_staff.id and closed_at is null and not abandoned
   order by opened_at desc limit 1;
  if v_id is null then return json_build_object('success', false, 'message', 'no open shift'); end if;

  -- A pump meter only counts up. A closing reading below the opening one is a
  -- typo, and accepting it would produce a negative variance that looks like
  -- fuel appearing out of nowhere.
  if p_closing_meter < v_open then
    return json_build_object('success', false,
      'message', 'the closing meter is below the opening one - check the reading');
  end if;

  update shifts set closing_meter = p_closing_meter, closed_at = now() where id = v_id;
  return json_build_object('success', true, 'message', 'shift closed');
end; $$;

create or replace function my_open_shift()
returns table (id uuid, opened_at timestamptz, opening_meter numeric)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.opened_at, sh.opening_meter
  from shifts sh
  where sh.staff_id = (select id from current_staff())
    and sh.closed_at is null and not sh.abandoned
  order by sh.opened_at desc limit 1;
$$;

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

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- REPAIR: rows already stranded
-- ===============================================================
-- Anything left open from before today would still block its owner, since
-- the new rule only marks a stale row when they next try. This clears the
-- backlog in one go:
--
--   update attendance set abandoned = true
--    where check_out is null and not abandoned
--      and (check_in at time zone app_timezone())::date
--          < (now() at time zone app_timezone())::date
--   returning staff_id, check_in;
--
--   update shifts set abandoned = true
--    where closed_at is null and not abandoned
--      and (opened_at at time zone app_timezone())::date
--          < (now() at time zone app_timezone())::date
--   returning staff_id, opened_at;
--
-- Look at what comes back before running the second one: an open shift from
-- earlier today is somebody currently working, and today's rows are left
-- alone by the date test on purpose.
--
-- ===============================================================
-- VERIFY
-- ===============================================================
--   select count(*) as still_blocking
--     from attendance
--    where check_out is null and not abandoned
--      and (check_in at time zone app_timezone())::date
--          < (now() at time zone app_timezone())::date;
--
-- Expect 0, and expect it to stay 0 from now on.


-- ============================================================================
-- 0016 - nozzles, and a shift that belongs to one
-- ============================================================================
begin;

-- ---------------------------------------------------------------
-- the nozzles
-- ---------------------------------------------------------------
create table if not exists nozzles (
  id         uuid primary key default gen_random_uuid(),
  station_id uuid not null references stations(id),
  label      text not null,
  fuel_type  text,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (station_id, label));

create index if not exists nozzles_station_idx on nozzles (station_id, active);

alter table nozzles enable row level security;
revoke all on nozzles from anon, authenticated;

-- Ten per branch, once. The fuel cycles through whatever that branch's tanks
-- actually hold, because a nozzle that dispenses a fuel the branch does not
-- stock is not a useful default. Rename or re-assign them in the app.
do $$
declare
  st record;
  fuels text[];
  i int;
begin
  for st in select id, name from stations loop
    if exists (select 1 from nozzles where station_id = st.id) then
      raise notice '% already has nozzles, leaving them alone', st.name;
      continue;
    end if;

    select coalesce(array_agg(distinct t.fuel_type order by t.fuel_type), array['Diesel'])
      into fuels
      from tanks t where t.station_id = st.id and t.fuel_type is not null;

    for i in 1..10 loop
      -- "Pump 1" rather than "N1": the label is read aloud at the forecourt,
      -- and it should be the word the people using it already say.
      insert into nozzles (station_id, label, fuel_type)
      values (st.id, 'Pump ' || i, fuels[1 + ((i - 1) % array_length(fuels, 1))]);
    end loop;
    raise notice '% : 10 nozzles created (%)', st.name, array_to_string(fuels, ', ');
  end loop;
end $$;

alter table shifts add column if not exists nozzle_id uuid references nozzles(id);
alter table sales  add column if not exists nozzle_id uuid references nozzles(id);

create index if not exists sales_nozzle_idx  on sales (nozzle_id, created_at);
create index if not exists shifts_nozzle_idx on shifts (nozzle_id) where closed_at is null;

-- One open shift per nozzle. Two people on the same pump at once would each
-- claim its meter movement, and neither figure would mean anything.
create unique index if not exists shifts_one_open_per_nozzle_idx
  on shifts (nozzle_id) where closed_at is null and not abandoned;

-- ---------------------------------------------------------------
-- reading them
-- ---------------------------------------------------------------
create or replace function list_nozzles(p_station_id uuid default null)
returns table (id uuid, station_id uuid, station_name text, label text,
               fuel_type text, active boolean,
               open_shift_id uuid, open_by text)
language sql stable security definer set search_path = public
as $$
  select n.id, n.station_id, st.name, n.label, n.fuel_type, n.active,
         sh.id, stf.full_name
    from nozzles n
    left join stations st on st.id = n.station_id
    left join lateral (
      select s.id, s.staff_id from shifts s
       where s.nozzle_id = n.id and s.closed_at is null and not s.abandoned
       order by s.opened_at desc limit 1
    ) sh on true
    left join staff stf on stf.id = sh.staff_id
   where (case when is_admin()
               then (p_station_id is null or n.station_id = p_station_id)
               else n.station_id = current_station() end)
   -- Shortest label first, then alphabetical: plain text sorting puts
   -- "Pump 10" between "Pump 1" and "Pump 2", which reads as a mistake to
   -- anybody scanning the list for their pump.
   order by st.name, length(n.label), n.label;
$$;

-- ---------------------------------------------------------------
-- shifts, now against a nozzle
-- ---------------------------------------------------------------
drop function if exists open_shift(numeric);
drop function if exists close_shift(numeric);

create or replace function open_shift(p_nozzle_id uuid, p_opening_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  v_noz   nozzles;
  v_open  shifts;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if v_staff.station_id is null then
    return json_build_object('success', false,
      'message', 'no branch assigned - ask the manager before opening a shift');
  end if;
  if p_opening_meter is null or p_opening_meter < 0 then
    return json_build_object('success', false, 'message', 'enter the opening meter reading');
  end if;

  select * into v_noz from nozzles where id = p_nozzle_id;
  if v_noz.id is null then
    return json_build_object('success', false, 'message', 'choose a nozzle');
  end if;
  -- A nozzle at another branch is not theirs to open, whatever the app sent.
  if v_noz.station_id <> v_staff.station_id then
    return json_build_object('success', false, 'message', 'that nozzle is at another branch');
  end if;
  if not v_noz.active then
    return json_build_object('success', false, 'message', 'that nozzle is out of service');
  end if;

  -- Somebody else already on this pump.
  select * into v_open from shifts
   where nozzle_id = p_nozzle_id and closed_at is null and not abandoned
   order by opened_at desc limit 1;

  if v_open.id is not null then
    if (v_open.opened_at at time zone app_timezone())::date
       = (now() at time zone app_timezone())::date then
      return json_build_object('success', false,
        'message', case when v_open.staff_id = v_staff.id
                        then 'you already have this nozzle open'
                        else 'somebody else has this nozzle open' end);
    end if;
    -- Left open overnight: no closing meter was ever read, so no variance can
    -- exist for it. Mark it rather than invent one.
    update shifts set abandoned = true where id = v_open.id;
  end if;

  insert into shifts (station_id, staff_id, nozzle_id, opening_meter, opened_at)
  values (v_staff.station_id, v_staff.id, p_nozzle_id, p_opening_meter, now());

  return json_build_object('success', true, 'message', 'shift opened on ' || v_noz.label);
end; $$;

create or replace function close_shift(p_shift_id uuid, p_closing_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); sh shifts;
begin
  if v_staff.id is null then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if p_closing_meter is null or p_closing_meter < 0 then
    return json_build_object('success', false, 'message', 'enter the closing meter reading');
  end if;

  select * into sh from shifts where id = p_shift_id;
  if sh.id is null then return json_build_object('success', false, 'message', 'no such shift'); end if;
  if sh.staff_id <> v_staff.id then
    return json_build_object('success', false, 'message', 'that is not your shift');
  end if;
  if sh.closed_at is not null or sh.abandoned then
    return json_build_object('success', false, 'message', 'that shift is already closed');
  end if;

  -- A pump meter only counts up. A lower closing reading is a typo, and
  -- accepting it would show fuel appearing out of nowhere.
  if p_closing_meter < sh.opening_meter then
    return json_build_object('success', false,
      'message', 'the closing meter is below the opening one - check the reading');
  end if;

  update shifts set closing_meter = p_closing_meter, closed_at = now() where id = sh.id;
  return json_build_object('success', true, 'message', 'shift closed');
end; $$;

-- Plural: one person may be on two pumps at once, which is the whole point.
create or replace function my_open_shifts()
returns table (id uuid, nozzle_id uuid, nozzle_label text, fuel_type text,
               opened_at timestamptz, opening_meter numeric, sold_liters numeric)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.nozzle_id, n.label, n.fuel_type, sh.opened_at, sh.opening_meter,
         coalesce((select sum(s.liters) from sales s
                    where s.nozzle_id = sh.nozzle_id
                      and not coalesce(s.voided, false)
                      and s.created_at >= sh.opened_at), 0)
    from shifts sh
    left join nozzles n on n.id = sh.nozzle_id
   where sh.staff_id = (select id from current_staff())
     and sh.closed_at is null and not sh.abandoned
   order by sh.opened_at;
$$;

-- ---------------------------------------------------------------
-- selling, from a nozzle
-- ---------------------------------------------------------------
drop function if exists record_sale(text, numeric, text, uuid);

create or replace function record_sale(
  p_nozzle_id uuid, p_liters numeric, p_payment text,
  p_credit_customer_id uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  v_noz   nozzles;
  v_price numeric;
  v_tank  int;
  v_fuel  text;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if v_staff.station_id is null then
    return json_build_object('success', false, 'message', 'no branch assigned');
  end if;
  if not (p_liters > 0) then
    return json_build_object('success', false, 'message', 'litres must be positive');
  end if;

  select * into v_noz from nozzles where id = p_nozzle_id;
  if v_noz.id is null or v_noz.station_id <> v_staff.station_id then
    return json_build_object('success', false, 'message', 'choose a nozzle at this branch');
  end if;

  -- The shift must be theirs AND on this nozzle. Selling from a pump you have
  -- not opened is how a meter reading stops matching what came out of it.
  if not exists (select 1 from shifts
                  where staff_id = v_staff.id and nozzle_id = p_nozzle_id
                    and closed_at is null and not abandoned) then
    return json_build_object('success', false, 'message', 'open a shift on this nozzle first');
  end if;

  -- The fuel is the nozzle's, not the seller's choice. A nozzle dispenses
  -- what it dispenses, and letting the till say otherwise is how stock and
  -- takings drift apart.
  v_fuel := v_noz.fuel_type;
  if v_fuel is null then
    return json_build_object('success', false, 'message', 'this nozzle has no fuel set - ask the manager');
  end if;

  select price_per_liter into v_price
    from fuel_prices where station_id = v_staff.station_id and fuel_type = v_fuel;
  if v_price is null then
    return json_build_object('success', false, 'message', 'no price set for ' || v_fuel);
  end if;

  if p_payment = 'credit' then
    if p_credit_customer_id is null then
      return json_build_object('success', false, 'message', 'choose a credit customer');
    end if;
    if not exists (select 1 from credit_customers
                    where id = p_credit_customer_id and station_id = v_staff.station_id) then
      return json_build_object('success', false, 'message', 'customer is not at this branch');
    end if;
  end if;

  select id into v_tank from tanks
   where station_id = v_staff.station_id and fuel_type = v_fuel
   order by current_liters desc limit 1;
  if v_tank is null then
    return json_build_object('success', false, 'message', 'no tank holds ' || v_fuel);
  end if;
  if (select current_liters from tanks where id = v_tank) < p_liters then
    return json_build_object('success', false, 'message', 'not enough stock in the tank');
  end if;

  insert into sales (station_id, staff_id, nozzle_id, fuel_type, liters, total_etb,
                     payment_method, credit_customer_id)
  values (v_staff.station_id, v_staff.id, p_nozzle_id, v_fuel, p_liters,
          round(p_liters * v_price, 2), p_payment, p_credit_customer_id);

  update tanks set current_liters = current_liters - p_liters where id = v_tank;

  if p_payment = 'credit' then
    update credit_customers set balance = balance + round(p_liters * v_price, 2)
     where id = p_credit_customer_id;
  end if;

  return json_build_object('success', true, 'message', 'sale recorded');
end; $$;

-- ---------------------------------------------------------------
-- what the admin sees
-- ---------------------------------------------------------------
-- sold_liters is now scoped to the NOZZLE, not the person. With two shifts
-- open at once, scoping by person would credit every sale to both of them and
-- make both variances wrong.
drop function if exists list_shifts(uuid, int, int);

create or replace function list_shifts(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text, nozzle_label text,
  opened_at timestamptz, closed_at timestamptz,
  opening_meter numeric, closing_meter numeric,
  metered_liters numeric, sold_liters numeric, variance_liters numeric,
  abandoned boolean)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.station_id, coalesce(st.name, '(no branch)'), stf.full_name,
         coalesce(n.label, '—'),
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
    left join nozzles n on n.id = sh.nozzle_id
    left join lateral (
      select sum(s.liters) as liters
        from sales s
       where s.nozzle_id is not distinct from sh.nozzle_id
         and s.staff_id = sh.staff_id
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

create or replace function admin_set_nozzle(
  p_nozzle_id uuid, p_label text default null,
  p_fuel_type text default null, p_active boolean default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;

  update nozzles
     set label     = coalesce(nullif(trim(p_label), ''), label),
         fuel_type = coalesce(nullif(trim(p_fuel_type), ''), fuel_type),
         active    = coalesce(p_active, active)
   where id = p_nozzle_id;

  if not found then return json_build_object('success', false, 'message', 'no such nozzle'); end if;
  return json_build_object('success', true, 'message', 'nozzle updated');
end; $$;

grant execute on function list_nozzles(uuid)                        to authenticated;
grant execute on function open_shift(uuid, numeric)                 to authenticated;
grant execute on function close_shift(uuid, numeric)                to authenticated;
grant execute on function my_open_shifts()                          to authenticated;
grant execute on function record_sale(uuid, numeric, text, uuid)    to authenticated;
grant execute on function list_shifts(uuid, int, int)               to authenticated;
grant execute on function admin_set_nozzle(uuid, text, text, boolean) to authenticated;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select station_name, count(*) from list_nozzles(null)
--    group by station_name order by station_name;
--
-- Expect 10 for each of the five branches.
--
-- Sales recorded before this migration have no nozzle. Their shifts keep the
-- variance they always had, which was never meaningful; from here on it is.
--
--   select count(*) as sales_without_a_nozzle from sales where nozzle_id is null;


-- ============================================================================
-- 0017 - the manager can close a pump
-- ============================================================================
begin;

alter table shifts add column if not exists closed_by uuid references staff(id);

-- Fill in what we can for shifts already closed: a shift closed before this
-- existed was closed by its own operator, because that was the only way.
update shifts set closed_by = staff_id
 where closed_at is not null and closed_by is null;

create or replace function close_shift(p_shift_id uuid, p_closing_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); sh shifts;
begin
  if v_staff.id is null then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if p_closing_meter is null or p_closing_meter < 0 then
    return json_build_object('success', false, 'message', 'enter the closing meter reading');
  end if;

  select * into sh from shifts where id = p_shift_id;
  if sh.id is null then return json_build_object('success', false, 'message', 'no such shift'); end if;

  -- An admin may close anyone's; a cashier only their own.
  if sh.staff_id <> v_staff.id and not is_admin() then
    return json_build_object('success', false, 'message', 'that is not your shift');
  end if;
  if sh.closed_at is not null or sh.abandoned then
    return json_build_object('success', false, 'message', 'that shift is already closed');
  end if;
  if p_closing_meter < sh.opening_meter then
    return json_build_object('success', false,
      'message', 'the closing meter is below the opening one - check the reading');
  end if;

  update shifts
     set closing_meter = p_closing_meter, closed_at = now(), closed_by = v_staff.id
   where id = sh.id;

  return json_build_object('success', true,
    'message', case when sh.staff_id = v_staff.id then 'shift closed'
                    else 'shift closed for them' end);
end; $$;

-- ---------------------------------------------------------------
-- and say so in the list
-- ---------------------------------------------------------------
drop function if exists list_shifts(uuid, int, int);

create or replace function list_shifts(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text, nozzle_label text,
  opened_at timestamptz, closed_at timestamptz,
  opening_meter numeric, closing_meter numeric,
  metered_liters numeric, sold_liters numeric, variance_liters numeric,
  abandoned boolean, closed_by_other boolean)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.station_id, coalesce(st.name, '(no branch)'), stf.full_name,
         coalesce(n.label, '-'),
         sh.opened_at, sh.closed_at, sh.opening_meter, sh.closing_meter,
         case when sh.closing_meter is null then null
              else sh.closing_meter - sh.opening_meter end,
         coalesce(sold.liters, 0),
         case when sh.closing_meter is null then null
              else (sh.closing_meter - sh.opening_meter) - coalesce(sold.liters, 0) end,
         sh.abandoned,
         -- A variance from a meter the operator never read is worth less than
         -- one they did. The column says which, rather than leaving both
         -- looking the same a week later.
         (sh.closed_by is not null and sh.closed_by <> sh.staff_id)
    from shifts sh
    left join stations st on st.id = sh.station_id
    left join staff stf on stf.id = sh.staff_id
    left join nozzles n on n.id = sh.nozzle_id
    left join lateral (
      select sum(s.liters) as liters
        from sales s
       where s.nozzle_id is not distinct from sh.nozzle_id
         and s.staff_id = sh.staff_id
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

grant execute on function close_shift(uuid, numeric)  to authenticated;
grant execute on function list_shifts(uuid, int, int) to authenticated;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select staff_name, nozzle_label, variance_liters, closed_by_other
--     from list_shifts(null, 7, 200) where closed_at is not null;
--
-- closed_by_other is true only where somebody other than the operator took
-- the reading.

-- ============================================================================
-- WHAT TO DO NEXT
-- ============================================================================
-- 1. Put this project's URL and publishable key into config.js
--    (Settings -> API. The publishable key only - never service_role.)
--
-- 2. Open the app and use "Create account" to sign yourself up.
--
-- 3. There is no admin yet, so promote yourself here, once:
--
--      update staff
--         set role = 'admin', status = 'approved', station_id = null
--       where email = 'YOUR-EMAIL';
--
--    station_id stays null on purpose: the central admin belongs to no single
--    branch, which is what makes the dashboard show all five.
--
-- 4. Sign in, set the fuel prices per branch, then have staff sign up. Approve
--    each one and give them a branch - without a branch they can sign in but
--    cannot sell.
