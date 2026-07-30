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
