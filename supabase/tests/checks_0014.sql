-- Checks for 0014: the backup must contain everything, and refuse everyone
-- who is not an admin.
--
--   psql -f supabase/tests/fixture.sql -f supabase/tests/auth_meta.sql \
--        -f supabase/migrations/0008_local_day.sql \
--        -f supabase/migrations/0012_corrections.sql \
--        -f supabase/migrations/0014_backup.sql \
--        -f supabase/tests/checks_0014.sql

do $$
declare
  v_admin_auth uuid := gen_random_uuid();
  v_op_auth    uuid := gen_random_uuid();
  v_op uuid; v_station uuid; v_tank int;
  v_b jsonb;
  v_n int;
  i int;
begin
  insert into auth.users (id, email) values (v_admin_auth,'a@x.com'), (v_op_auth,'o@x.com');
  insert into stations (name, town) values ('Adama','East Shewa') returning id into v_station;
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_admin_auth,'Owner','admin','approved',null);
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_op_auth,'Abebe','operator','approved',v_station) returning id into v_op;

  insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
  values (v_station,'T1','Diesel',10000,5000) returning id into v_tank;
  insert into fuel_prices (station_id, fuel_type, price_per_liter)
  values (v_station,'Diesel',95);

  -- More than the 500-row cap the listing functions impose. This is the whole
  -- reason the backup does not reuse them: an export built on list_sales
  -- would stop here and say nothing.
  for i in 1..600 loop
    insert into sales (station_id, staff_id, fuel_type, liters, total_etb, payment_method)
    values (v_station, v_op, 'Diesel', 10, 950, 'cash');
  end loop;

  -- ---------------------------------------------------------------
  -- 1. a non-admin gets nothing
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_op_auth::text, false);
  v_b := admin_backup()::jsonb;
  if (v_b ->> 'error') <> 'not authorised' then
    raise exception 'an operator was given a backup: %', left(v_b::text, 200);
  end if;
  if v_b ? 'sales' then
    raise exception 'a refused backup still carried data';
  end if;

  -- ---------------------------------------------------------------
  -- 2. an admin gets all of it, past the cap
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_admin_auth::text, false);
  v_b := admin_backup()::jsonb;

  if (v_b -> 'counts' ->> 'sales')::int <> 600 then
    raise exception 'counts say % sales, expected 600', v_b -> 'counts' ->> 'sales';
  end if;

  select jsonb_array_length(v_b -> 'sales') into v_n;
  if v_n <> 600 then
    raise exception 'the file holds % sales, not 600 - it is truncating', v_n;
  end if;

  -- The count and the rows must agree with each other. A count that says 600
  -- over an array of 500 would be the worst outcome: believable and wrong.
  if v_n <> (v_b -> 'counts' ->> 'sales')::int then
    raise exception 'the stated count and the rows disagree: % vs %',
      v_b -> 'counts' ->> 'sales', v_n;
  end if;

  -- ---------------------------------------------------------------
  -- 3. every table is present, even when empty
  -- ---------------------------------------------------------------
  -- An absent key reads as "this table does not exist"; an empty array reads
  -- as "there was nothing in it". Those are different facts.

  if not (v_b ? 'stations' and v_b ? 'staff' and v_b ? 'tanks'
          and v_b ? 'fuel_prices' and v_b ? 'sales' and v_b ? 'credit_customers'
          and v_b ? 'expenses' and v_b ? 'shifts' and v_b ? 'attendance'
          and v_b ? 'deliveries' and v_b ? 'price_history'
          and v_b ? 'sale_corrections') then
    raise exception 'a table is missing from the backup';
  end if;

  if jsonb_array_length(v_b -> 'expenses') <> 0 then
    raise exception 'an empty table should be an empty array, got %', v_b -> 'expenses';
  end if;

  if (v_b ->> 'magpms_backup_version') is null then
    raise exception 'the file does not say what version it is';
  end if;
  if (v_b ->> 'generated_at') is null then
    raise exception 'the file does not say when it was made';
  end if;

  -- ---------------------------------------------------------------
  -- 4. no credential material
  -- ---------------------------------------------------------------
  -- 0009 dropped password_hash; this is the check that keeps it dropped.
  if v_b::text ilike '%password_hash%' or v_b::text ilike '%encrypted_password%' then
    raise exception 'the backup carries password material';
  end if;

  raise notice 'backup: ok (% sales, past the 500 cap)', v_n;
end $$;
