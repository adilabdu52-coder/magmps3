-- MAGPMS install 13 of 19 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

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

revoke all on all tables in schema public from anon, authenticated;

grant execute on all functions in schema public to authenticated;

grant execute on function register_staff(text, text) to anon;

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
