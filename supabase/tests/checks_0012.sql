-- Checks for 0012: corrections must leave the sale, the tank and the
-- customer's balance telling the same story.
--
--   psql -f supabase/tests/fixture.sql -f supabase/tests/auth_meta.sql \
--        -f supabase/migrations/0012_corrections.sql \
--        -f supabase/tests/checks_0012.sql
--
-- Every check raises on failure, so a clean run is a pass.

do $$
declare
  v_admin_auth uuid := gen_random_uuid();
  v_op_auth    uuid := gen_random_uuid();
  v_other_auth uuid := gen_random_uuid();
  v_admin uuid; v_op uuid; v_other uuid;
  v_station uuid; v_cust uuid;
  v_tank int; v_tank2 int;
  v_sale uuid; v_credit_sale uuid;
  v_corr uuid;
  v_res json;
  v_n numeric; v_m numeric;
begin
  insert into auth.users (id, email) values
    (v_admin_auth,'a@x.com'), (v_op_auth,'o@x.com'), (v_other_auth,'z@x.com');
  insert into stations (name, town) values ('Adama','East Shewa') returning id into v_station;

  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_admin_auth,'Owner','admin','approved',null) returning id into v_admin;
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_op_auth,'Abebe','operator','approved',v_station) returning id into v_op;
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_other_auth,'Chaltu','operator','approved',v_station) returning id into v_other;

  insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
  values (v_station,'T1','Diesel',10000,8000) returning id into v_tank;
  insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
  values (v_station,'T2','Diesel',10000,2000) returning id into v_tank2;

  insert into credit_customers (station_id, name, balance)
  values (v_station,'Garage Ltd',0) returning id into v_cust;

  -- A cash sale: 1000 litres typed instead of 100, at 95/litre.
  insert into sales (station_id, staff_id, fuel_type, liters, total_etb, payment_method)
  values (v_station, v_op, 'Diesel', 1000, 95000, 'cash') returning id into v_sale;

  -- ---------------------------------------------------------------
  -- 1. reporting
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_other_auth::text, false);
  v_res := report_sale_mistake(v_sale, 'wrong amount', 100);
  if (v_res ->> 'message') <> 'that is not your sale' then
    raise exception 'a cashier reported someone else''s sale: %', v_res;
  end if;

  perform set_config('test.uid', v_op_auth::text, false);

  v_res := report_sale_mistake(v_sale, '   ', 100);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'an empty reason was accepted: %', v_res;
  end if;

  v_res := report_sale_mistake(v_sale, 'typed 1000 instead of 100', 0);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'zero litres was accepted: %', v_res;
  end if;

  v_res := report_sale_mistake(v_sale, 'typed 1000 instead of 100', 100);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'a valid report was refused: %', v_res;
  end if;

  -- Twice is the dangerous case: two open reports means one mistake
  -- corrected twice, and a tank adjusted twice for it.
  v_res := report_sale_mistake(v_sale, 'again', 100);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'a second open report was allowed: %', v_res;
  end if;

  if (select count(*) from my_corrections(20)) <> 1 then
    raise exception 'the cashier cannot see their own report';
  end if;

  -- ---------------------------------------------------------------
  -- 2. only an admin decides
  -- ---------------------------------------------------------------
  select id into v_corr from sale_corrections where sale_id = v_sale;

  v_res := admin_resolve_correction(v_corr, 'fix', 100, null);
  if (v_res ->> 'message') <> 'not authorised' then
    raise exception 'an operator resolved a correction: %', v_res;
  end if;

  perform set_config('test.uid', v_admin_auth::text, false);

  v_res := admin_resolve_correction(v_corr, 'nonsense', 100, null);
  if (v_res ->> 'message') <> 'unknown action' then
    raise exception 'an unknown action was accepted: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 3. fixing downwards: fuel goes back, at the sale's own price
  -- ---------------------------------------------------------------
  v_res := admin_resolve_correction(v_corr, 'fix', 100, 'confirmed with the customer');
  if (v_res ->> 'success') <> 'true' then
    raise exception 'a valid fix was refused: %', v_res;
  end if;

  select liters, total_etb into v_n, v_m from sales where id = v_sale;
  if v_n <> 100 then raise exception 'litres are % not 100', v_n; end if;
  -- 95 000 / 1000 = 95 a litre, so 100 litres is 9 500. Re-priced at the
  -- sale's own rate, not at whatever the price is now.
  if v_m <> 9500 then raise exception 'total is % not 9500', v_m; end if;

  -- 900 litres come back, into the EMPTIER tank: 2000 -> 2900.
  select current_liters into v_n from tanks where id = v_tank2;
  if v_n <> 2900 then raise exception 'emptier tank is % not 2900', v_n; end if;
  select current_liters into v_n from tanks where id = v_tank;
  if v_n <> 8000 then raise exception 'the fuller tank moved: %', v_n; end if;

  if (select status from sale_corrections where id = v_corr) <> 'fixed' then
    raise exception 'the report was not marked fixed';
  end if;
  if (select old_liters from sale_corrections where id = v_corr) <> 1000
     or (select new_liters from sale_corrections where id = v_corr) <> 100 then
    raise exception 'the before/after numbers were not recorded';
  end if;

  -- Resolving twice would adjust the tank a second time.
  v_res := admin_resolve_correction(v_corr, 'fix', 50, null);
  if (v_res ->> 'message') <> 'already dealt with' then
    raise exception 'a resolved report was resolved again: %', v_res;
  end if;

  raise notice 'report and fix: ok';
end $$;

-- ---------------------------------------------------------------
-- 4. fixing upwards, and the guard against a negative tank
-- ---------------------------------------------------------------
do $$
declare
  v_op_auth uuid; v_admin_auth uuid;
  v_op uuid; v_station uuid; v_tank int;
  v_sale uuid; v_corr uuid; v_res json; v_n numeric;
begin
  select auth_user_id into v_op_auth from staff where full_name = 'Abebe';
  select auth_user_id into v_admin_auth from staff where role = 'admin';
  select id into v_op from staff where full_name = 'Abebe';
  select id into v_station from stations limit 1;

  insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
  values (v_station,'T3','Benzil',10000,300) returning id into v_tank;

  -- Sold 10 litres, should have been 500. The tank holds 300.
  insert into sales (station_id, staff_id, fuel_type, liters, total_etb, payment_method)
  values (v_station, v_op, 'Benzil', 10, 900, 'cash') returning id into v_sale;

  perform set_config('test.uid', v_op_auth::text, false);
  perform report_sale_mistake(v_sale, 'entered 10, was 500', 500);
  select id into v_corr from sale_corrections where sale_id = v_sale;

  perform set_config('test.uid', v_admin_auth::text, false);
  v_res := admin_resolve_correction(v_corr, 'fix', 500, null);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'a correction larger than the tank was accepted: %', v_res;
  end if;
  if (v_res ->> 'message') not like '%does not hold enough%' then
    raise exception 'unhelpful refusal: %', v_res;
  end if;

  -- Nothing may have moved on a refusal.
  select current_liters into v_n from tanks where id = v_tank;
  if v_n <> 300 then raise exception 'the tank moved on a refused fix: %', v_n; end if;
  select liters into v_n from sales where id = v_sale;
  if v_n <> 10 then raise exception 'the sale moved on a refused fix: %', v_n; end if;
  if (select status from sale_corrections where id = v_corr) <> 'open' then
    raise exception 'a refused fix closed the report';
  end if;

  -- A correction the tank CAN take goes through, and takes from stock.
  v_res := admin_resolve_correction(v_corr, 'fix', 60, null);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'an affordable correction was refused: %', v_res;
  end if;
  select current_liters into v_n from tanks where id = v_tank;
  if v_n <> 250 then raise exception 'tank is % not 250', v_n; end if;   -- 300 - (60-10)
  select total_etb into v_n from sales where id = v_sale;
  if v_n <> 5400 then raise exception 'total is % not 5400', v_n; end if; -- 90/L * 60

  raise notice 'upward fix and the tank guard: ok';
end $$;

-- ---------------------------------------------------------------
-- 5. credit follows the money
-- ---------------------------------------------------------------
do $$
declare
  v_op_auth uuid; v_admin_auth uuid; v_op uuid; v_station uuid;
  v_cust uuid; v_sale uuid; v_corr uuid; v_res json; v_n numeric;
begin
  select auth_user_id into v_op_auth from staff where full_name = 'Abebe';
  select auth_user_id into v_admin_auth from staff where role = 'admin';
  select id into v_op from staff where full_name = 'Abebe';
  select id into v_station from stations limit 1;
  select id into v_cust from credit_customers limit 1;

  update credit_customers set balance = 9500 where id = v_cust;

  insert into sales (station_id, staff_id, fuel_type, liters, total_etb,
                     payment_method, credit_customer_id)
  values (v_station, v_op, 'Diesel', 100, 9500, 'credit', v_cust) returning id into v_sale;

  perform set_config('test.uid', v_op_auth::text, false);
  perform report_sale_mistake(v_sale, 'should have been 40', 40);
  select id into v_corr from sale_corrections where sale_id = v_sale;

  perform set_config('test.uid', v_admin_auth::text, false);
  v_res := admin_resolve_correction(v_corr, 'fix', 40, null);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'the credit correction was refused: %', v_res;
  end if;

  -- 9500 owed, corrected to 3800: the customer owes 5700 less.
  select balance into v_n from credit_customers where id = v_cust;
  if v_n <> 3800 then raise exception 'balance is % not 3800', v_n; end if;

  raise notice 'credit follows the correction: ok';
end $$;

-- ---------------------------------------------------------------
-- 6. rejecting changes nothing but the record
-- ---------------------------------------------------------------
do $$
declare
  v_op_auth uuid; v_admin_auth uuid; v_op uuid; v_station uuid;
  v_sale uuid; v_corr uuid; v_res json; v_n numeric; v_before numeric;
begin
  select auth_user_id into v_op_auth from staff where full_name = 'Abebe';
  select auth_user_id into v_admin_auth from staff where role = 'admin';
  select id into v_op from staff where full_name = 'Abebe';
  select id into v_station from stations limit 1;

  insert into sales (station_id, staff_id, fuel_type, liters, total_etb, payment_method)
  values (v_station, v_op, 'Diesel', 25, 2375, 'cash') returning id into v_sale;

  select sum(current_liters) into v_before from tanks;

  perform set_config('test.uid', v_op_auth::text, false);
  perform report_sale_mistake(v_sale, 'thought it was wrong', 12);
  select id into v_corr from sale_corrections where sale_id = v_sale;

  perform set_config('test.uid', v_admin_auth::text, false);
  v_res := admin_resolve_correction(v_corr, 'reject', null, 'meter agrees with the sale');
  if (v_res ->> 'success') <> 'true' then
    raise exception 'a rejection failed: %', v_res;
  end if;

  select liters into v_n from sales where id = v_sale;
  if v_n <> 25 then raise exception 'a rejection changed the sale: %', v_n; end if;
  select sum(current_liters) into v_n from tanks;
  if v_n <> v_before then raise exception 'a rejection moved stock: % vs %', v_n, v_before; end if;
  if (select resolution_note from sale_corrections where id = v_corr)
     <> 'meter agrees with the sale' then
    raise exception 'the reason for rejecting was not kept';
  end if;

  -- Once rejected, the cashier may report it again - a rejection is a
  -- decision about one claim, not a permanent gag.
  perform set_config('test.uid', v_op_auth::text, false);
  v_res := report_sale_mistake(v_sale, 'still looks wrong to me', 12);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'a rejected sale could not be reported again: %', v_res;
  end if;

  raise notice 'rejection: ok';
end $$;
