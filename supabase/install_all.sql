-- MAGPMS — every migration in one file
-- ============================================================================
--
--   0001 identity      0004 rpcs        0007 shifts & reports
--   0002 stations      0005 lockdown    0008 local day
--   0003 price history 0006 deliveries  0009 drop password_hash
--
-- Safe to run more than once. Every step checks before it acts, so re-running
-- reports "already present" rather than failing or duplicating anything.
--
-- ----------------------------------------------------------------------------
-- BEFORE YOU PRESS RUN: check which project you are in
-- ----------------------------------------------------------------------------
-- The address bar must contain this project ref:
--
--     https://supabase.com/dashboard/project/lnqwooqpnlxifxeukozd/sql
--
-- A night was lost to running these against a different project that happened
-- to have a `staff` table too. Every error that followed - "current_staff()
-- does not exist", "me() not in the schema cache", passwords that would not
-- work - was that one mistake wearing different masks.
--
-- The guard below catches an empty or unrelated database. It cannot read your
-- address bar. Look at the URL.
--
-- ----------------------------------------------------------------------------
-- WHAT THIS DOES NOT DO
-- ----------------------------------------------------------------------------
-- It does not create staff, tanks, sales, fuel_prices, shifts, attendance,
-- expenses or credit_customers. Those came with the original app and are
-- assumed to exist. This upgrades that schema; it does not build one.
-- ============================================================================

-- Resolve names explicitly rather than trusting the session. The SQL editor
-- does not always put public on the search_path, and a function body is parsed
-- with the CREATING session's path - not the `set search_path` written into the
-- function itself. That single subtlety produced hours of "does not exist" for
-- functions that were present the whole time.
set search_path = public, extensions;

-- ----------------------------------------------------------------------------
-- guard: is this the right kind of database at all?
-- ----------------------------------------------------------------------------
do $guard$
declare
  missing text := '';
  t text;
begin
  foreach t in array array['staff','tanks','sales','fuel_prices'] loop
    if to_regclass('public.' || t) is null then
      missing := missing || ' ' || t;
    end if;
  end loop;

  if missing <> '' then
    raise exception
      E'This database is missing tables the migrations expect:%s\n\n'
      'That usually means the SQL editor is connected to the wrong project.\n'
      'Check the ref in the address bar against config.js before re-running.',
      missing;
  end if;

  raise notice 'base tables present - proceeding';
end $guard$;





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
--     "https://lnqwooqpnlxifxeukozd.supabase.co",
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
-- FINISH: tell PostgREST the schema changed
-- ============================================================================
-- Without this the API keeps serving from a cached picture taken before these
-- ran, and every RPC fails with "Could not find the function public.me without
-- parameters in the schema cache" - which reads as though the function has been
-- deleted when it is sitting there intact.
notify pgrst, 'reload schema';

-- ============================================================================
-- REPORT: what the database looks like now
-- ============================================================================
do $report$
declare
  v_stations int; v_staff int; v_linked int; v_tanks int; v_fns int; v_rls int;
begin
  select count(*) into v_stations from stations;
  select count(*) into v_staff    from staff;
  select count(*) into v_linked   from staff where auth_user_id is not null;
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
  raise notice 'branches ................ %', v_stations;
  raise notice 'tanks ................... %', v_tanks;
  raise notice 'staff ................... % (% can sign in)', v_staff, v_linked;
  raise notice 'key functions present ... % of 10', v_fns;
  raise notice 'tables with RLS on ...... %', v_rls;
  raise notice '--------------------------------------------------';

  if v_fns < 10 then
    raise notice 'SOME FUNCTIONS ARE MISSING - scroll up for the error that stopped them';
  end if;
  if v_linked < v_staff then
    raise notice '% staff have no auth account and cannot sign in yet', v_staff - v_linked;
  end if;
end $report$;

-- ============================================================================
-- AFTERWARDS
-- ============================================================================
-- 1. Sign out of the app, close the tab, reopen it, sign in. That exercises
--    me(), which is where a broken identity layer shows up first.
--
-- 2. If the app reports a schema cache error anyway:
--       Settings -> General -> Restart project
--    That rebuilds the cache from nothing and always clears it.
--
-- 3. Nothing here touches passwords. Supabase Auth keeps those as bcrypt in
--    auth.users, in a schema this app has never been granted access to.
