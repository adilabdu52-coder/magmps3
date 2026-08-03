-- MAGPMS install 4 of 44 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

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

revoke update, delete on price_history from authenticated, anon;
