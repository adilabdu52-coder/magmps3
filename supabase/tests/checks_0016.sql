-- Checks for 0016: a shift belongs to a nozzle, and the variance finally
-- means something.
--
--   psql -f supabase/tests/fixture.sql -f supabase/tests/auth_meta.sql \
--        -f supabase/migrations/0007_shifts_reports.sql \
--        -f supabase/migrations/0008_local_day.sql \
--        -f supabase/migrations/0015_shift_attendance_fixes.sql \
--        -f supabase/migrations/0016_nozzles.sql \
--        -f supabase/tests/checks_0016.sql

do $$
declare
  v_admin_auth uuid := gen_random_uuid();
  v_a_auth uuid := gen_random_uuid();
  v_b_auth uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_s1 uuid; v_s2 uuid;
  n1 uuid; n2 uuid; n_other uuid;
  v_res json; v_n int; v_v numeric;
  v_shift1 uuid; v_shift2 uuid;
begin
  insert into auth.users (id, email) values
    (v_admin_auth,'ad@x.com'), (v_a_auth,'a@x.com'), (v_b_auth,'b@x.com');
  insert into stations (name) values ('Adama') returning id into v_s1;
  insert into stations (name) values ('Hirna') returning id into v_s2;

  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_admin_auth,'Owner','admin','approved',null);
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_a_auth,'Abebe','operator','approved',v_s1) returning id into v_a;
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_b_auth,'Chaltu','operator','approved',v_s1) returning id into v_b;

  insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
  values (v_s1,'T1','Diesel',10000,9000), (v_s2,'T1','Diesel',10000,9000);
  insert into fuel_prices (station_id, fuel_type, price_per_liter)
  values (v_s1,'Diesel',95), (v_s2,'Diesel',95);

  -- The seed in 0016 ran before these stations existed, so make the nozzles
  -- this test needs directly.
  insert into nozzles (station_id, label, fuel_type) values (v_s1,'N1','Diesel') returning id into n1;
  insert into nozzles (station_id, label, fuel_type) values (v_s1,'N2','Diesel') returning id into n2;
  insert into nozzles (station_id, label, fuel_type) values (v_s2,'N1','Diesel') returning id into n_other;

  perform set_config('test.uid', v_a_auth::text, false);

  -- ---------------------------------------------------------------
  -- 1. a nozzle at another branch is not theirs
  -- ---------------------------------------------------------------
  v_res := open_shift(n_other, 1000);
  if (v_res ->> 'message') <> 'that nozzle is at another branch' then
    raise exception 'a cashier opened a nozzle at another branch: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 2. one person, two pumps
  -- ---------------------------------------------------------------
  v_res := open_shift(n1, 1000);
  if (v_res ->> 'success') <> 'true' then raise exception 'opening N1 failed: %', v_res; end if;
  v_res := open_shift(n2, 5000);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'a second nozzle was refused - the whole point is two pumps at once: %', v_res;
  end if;

  if (select count(*) from my_open_shifts()) <> 2 then
    raise exception 'my_open_shifts does not show both';
  end if;

  -- Same nozzle twice is still refused.
  v_res := open_shift(n1, 1200);
  if (v_res ->> 'message') <> 'you already have this nozzle open' then
    raise exception 'the same nozzle was opened twice: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 3. two people cannot share a pump
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_b_auth::text, false);
  v_res := open_shift(n1, 1000);
  if (v_res ->> 'message') <> 'somebody else has this nozzle open' then
    raise exception 'two people opened the same nozzle: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 4. selling is tied to the nozzle you opened
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_a_auth::text, false);

  -- 40 litres from N1, 10 from N2.
  v_res := record_sale(n1, 40, 'cash');
  if (v_res ->> 'success') <> 'true' then raise exception 'a sale on N1 failed: %', v_res; end if;
  v_res := record_sale(n2, 10, 'cash');
  if (v_res ->> 'success') <> 'true' then raise exception 'a sale on N2 failed: %', v_res; end if;

  -- Chaltu has no shift on N2, so she cannot sell from it.
  perform set_config('test.uid', v_b_auth::text, false);
  v_res := record_sale(n2, 5, 'cash');
  if (v_res ->> 'message') <> 'open a shift on this nozzle first' then
    raise exception 'somebody sold from a pump they had not opened: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 5. the variance is per nozzle, which is the entire point
  -- ---------------------------------------------------------------
  -- N1: meter moves 50, 40 sold  -> 10 missing.
  -- N2: meter moves 10, 10 sold  ->  0.
  -- Scoped by person instead of nozzle, each shift would claim all 50 litres
  -- sold and both variances would be wrong.
  perform set_config('test.uid', v_a_auth::text, false);
  select id into v_shift1 from shifts where nozzle_id = n1 and closed_at is null;
  select id into v_shift2 from shifts where nozzle_id = n2 and closed_at is null;

  /* Inside one transaction now() is frozen, so every row above carries the
     same timestamp - and the shift window is `created_at < closed_at`, which
     is false when they are equal. Real life has time passing between opening
     a pump, selling, and closing it. Push these apart so the test measures
     the window rather than the clock standing still. */
  update shifts set opened_at = now() - interval '2 hours' where id in (v_shift1, v_shift2);
  update sales  set created_at = now() - interval '1 hour'  where staff_id = v_a;

  v_res := close_shift(v_shift1, 1050);
  if (v_res ->> 'success') <> 'true' then raise exception 'closing N1 failed: %', v_res; end if;
  v_res := close_shift(v_shift2, 5010);
  if (v_res ->> 'success') <> 'true' then raise exception 'closing N2 failed: %', v_res; end if;

  perform set_config('test.uid', v_admin_auth::text, false);

  select variance_liters into v_v from list_shifts(null, 7, 200) where id = v_shift1;
  if v_v <> 10 then raise exception 'N1 variance is % not 10', v_v; end if;

  select variance_liters into v_v from list_shifts(null, 7, 200) where id = v_shift2;
  if v_v <> 0 then raise exception 'N2 variance is % not 0', v_v; end if;

  if (select nozzle_label from list_shifts(null, 7, 200) where id = v_shift1) <> 'N1' then
    raise exception 'the shift does not say which nozzle it was';
  end if;

  -- ---------------------------------------------------------------
  -- 6. closing somebody else's shift
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_a_auth::text, false);
  v_res := open_shift(n1, 1050);
  select id into v_shift1 from shifts where nozzle_id = n1 and closed_at is null;

  perform set_config('test.uid', v_b_auth::text, false);
  v_res := close_shift(v_shift1, 1100);
  if (v_res ->> 'message') <> 'that is not your shift' then
    raise exception 'somebody closed another person''s shift: %', v_res;
  end if;

  raise notice 'nozzles, shifts and per-nozzle variance: ok';
end $$;

-- ---------------------------------------------------------------
-- 7. the fuel comes from the nozzle
-- ---------------------------------------------------------------
-- A nozzle dispenses what it dispenses. Letting the till claim otherwise is
-- how stock and takings drift apart.
do $$
declare
  v_a_auth uuid; v_s1 uuid; n3 uuid; v_res json; v_fuel text; v_n int;
begin
  select auth_user_id into v_a_auth from staff where full_name = 'Abebe';
  select id into v_s1 from stations where name = 'Adama';

  insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
  values (v_s1,'T2','Benzil',10000,9000);
  insert into fuel_prices (station_id, fuel_type, price_per_liter) values (v_s1,'Benzil',90);
  insert into nozzles (station_id, label, fuel_type) values (v_s1,'N3','Benzil') returning id into n3;

  perform set_config('test.uid', v_a_auth::text, false);
  perform open_shift(n3, 0);
  v_res := record_sale(n3, 5, 'cash');
  if (v_res ->> 'success') <> 'true' then raise exception 'a Benzil sale failed: %', v_res; end if;

  select fuel_type into v_fuel from sales where nozzle_id = n3 order by created_at desc limit 1;
  if v_fuel <> 'Benzil' then raise exception 'the sale recorded % not Benzil', v_fuel; end if;

  -- Priced from the nozzle's fuel, not another one: 5 x 90.
  if (select total_etb from sales where nozzle_id = n3 order by created_at desc limit 1) <> 450 then
    raise exception 'the sale was priced from the wrong fuel';
  end if;

  -- And the right tank moved.
  if (select current_liters from tanks where station_id = v_s1 and fuel_type = 'Benzil') <> 8995 then
    raise exception 'the Benzil tank did not move by 5';
  end if;

  -- A nozzle with no fuel set cannot sell, and says so.
  insert into nozzles (station_id, label, fuel_type) values (v_s1,'N4',null) returning id into n3;
  perform open_shift(n3, 0);
  v_res := record_sale(n3, 1, 'cash');
  if (v_res ->> 'message') not like '%no fuel set%' then
    raise exception 'a nozzle with no fuel sold something: %', v_res;
  end if;

  raise notice 'fuel follows the nozzle: ok';
end $$;

-- ---------------------------------------------------------------
-- 8. ten per branch, and only an admin renames one
-- ---------------------------------------------------------------
do $$
declare v_admin_auth uuid; v_a_auth uuid; v_id uuid; v_res json;
begin
  select auth_user_id into v_admin_auth from staff where role = 'admin';
  select auth_user_id into v_a_auth from staff where full_name = 'Abebe';

  perform set_config('test.uid', v_a_auth::text, false);
  select id into v_id from nozzles where label = 'N1' limit 1;
  v_res := admin_set_nozzle(v_id, 'Renamed', null, null);
  if (v_res ->> 'message') <> 'not authorised' then
    raise exception 'an operator renamed a nozzle: %', v_res;
  end if;

  perform set_config('test.uid', v_admin_auth::text, false);
  v_res := admin_set_nozzle(v_id, 'Pump 1', null, false);
  if (v_res ->> 'success') <> 'true' then raise exception 'an admin could not rename: %', v_res; end if;
  if (select label from nozzles where id = v_id) <> 'Pump 1' then
    raise exception 'the rename did not stick';
  end if;

  -- A missing id must not report success - the same fault 0011 fixed.
  v_res := admin_set_nozzle('00000000-0000-0000-0000-000000000000'::uuid, 'x', null, null);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'renaming a nozzle that does not exist reported success: %', v_res;
  end if;

  -- Out of service means out of service.
  perform set_config('test.uid', v_a_auth::text, false);
  v_res := open_shift(v_id, 10);
  if (v_res ->> 'message') <> 'that nozzle is out of service' then
    raise exception 'a disabled nozzle was opened: %', v_res;
  end if;

  raise notice 'nozzle management: ok';
end $$;
