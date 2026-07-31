-- MAGPMS install 3 of 24 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

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

create or replace function current_station()
returns uuid
language sql stable security definer set search_path = public
as $$
  select station_id from current_staff();
$$;
