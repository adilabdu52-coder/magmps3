-- 0002 — five branches
--
-- ⚠ VERIFY the table list below against your real schema before running.
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

-- Every table that holds branch-specific data gains a station.
alter table staff            add column if not exists station_id uuid references stations(id);
alter table tanks            add column if not exists station_id uuid references stations(id);
alter table nozzles          add column if not exists station_id uuid references stations(id);
alter table sales            add column if not exists station_id uuid references stations(id);
alter table shifts           add column if not exists station_id uuid references stations(id);
alter table nozzle_readings  add column if not exists station_id uuid references stations(id);
alter table attendance       add column if not exists station_id uuid references stations(id);
alter table expenses         add column if not exists station_id uuid references stations(id);
alter table prices           add column if not exists station_id uuid references stations(id);
alter table credit_customers add column if not exists station_id uuid references stations(id);

-- Existing rows all belong to the original branch.
do $$
declare v_first uuid := (select id from stations where name = 'Hirna');
begin
  update tanks            set station_id = v_first where station_id is null;
  update nozzles          set station_id = v_first where station_id is null;
  update sales            set station_id = v_first where station_id is null;
  update shifts           set station_id = v_first where station_id is null;
  update nozzle_readings  set station_id = v_first where station_id is null;
  update attendance       set station_id = v_first where station_id is null;
  update expenses         set station_id = v_first where station_id is null;
  update prices           set station_id = v_first where station_id is null;
  update credit_customers set station_id = v_first where station_id is null;
  -- staff.station_id stays nullable on purpose: null means the central admin,
  -- who is not tied to a branch.
  update staff set station_id = v_first where station_id is null and role <> 'admin';
end $$;

alter table tanks            alter column station_id set not null;
alter table nozzles          alter column station_id set not null;
alter table sales            alter column station_id set not null;
alter table shifts           alter column station_id set not null;
alter table nozzle_readings  alter column station_id set not null;
alter table attendance       alter column station_id set not null;
alter table expenses         alter column station_id set not null;
alter table prices           alter column station_id set not null;
alter table credit_customers alter column station_id set not null;

-- Prices are per branch now: one row per (station, fuel), not one per fuel.
-- Before this, setting the diesel price changed it at every site at once.
alter table prices drop constraint if exists prices_fuel_type_key;   -- ⚠ verify the real name
create unique index if not exists prices_station_fuel_key on prices (station_id, fuel_type);

create index if not exists sales_station_created_idx      on sales (station_id, created_at desc);
create index if not exists shifts_station_opened_idx      on shifts (station_id, opened_at desc);
create index if not exists attendance_station_in_idx      on attendance (station_id, check_in desc);
create index if not exists expenses_station_created_idx   on expenses (station_id, created_at desc);
create index if not exists tanks_station_idx              on tanks (station_id);
create index if not exists credit_customers_station_idx   on credit_customers (station_id);

commit;

-- Seed the tank layout for every branch: 1 benzil + 3 diesel, 50,000 L each.
-- Run once; adjust the fuel names to match what the prices table holds.
do $$
declare s record;
begin
  for s in select id from stations loop
    insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
    select s.id, v.n, v.f, 50000, 0
    from (values ('Tank 1','Benzil'), ('Tank 2','Diesel'),
                 ('Tank 3','Diesel'), ('Tank 4','Diesel')) as v(n,f)
    where not exists (
      select 1 from tanks t where t.station_id = s.id and t.tank_name = v.n
    );
  end loop;
end $$;
