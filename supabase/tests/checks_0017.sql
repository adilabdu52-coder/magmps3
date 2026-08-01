-- Checks for 0017: a manager can close a pump, and the row says who did.
--
--   ... fixture, auth_meta, 0007, 0008, 0015, 0016, 0017, then this file.

do $$
declare
  v_admin_auth uuid := gen_random_uuid();
  v_a_auth uuid := gen_random_uuid();
  v_b_auth uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_s uuid; n1 uuid; n2 uuid;
  v_sh uuid; v_res json; v_flag boolean;
begin
  insert into auth.users (id, email) values
    (v_admin_auth,'ad@x.com'), (v_a_auth,'a@x.com'), (v_b_auth,'b@x.com');
  insert into stations (name) values ('Adama') returning id into v_s;

  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_admin_auth,'Owner','admin','approved',null);
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_a_auth,'Abebe','operator','approved',v_s) returning id into v_a;
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_b_auth,'Chaltu','operator','approved',v_s) returning id into v_b;

  insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
  values (v_s,'T1','Diesel',10000,9000);
  insert into fuel_prices (station_id, fuel_type, price_per_liter) values (v_s,'Diesel',95);
  insert into nozzles (station_id, label, fuel_type) values (v_s,'Pump 1','Diesel') returning id into n1;
  insert into nozzles (station_id, label, fuel_type) values (v_s,'Pump 2','Diesel') returning id into n2;

  -- Abebe opens a pump and goes home without closing it.
  perform set_config('test.uid', v_a_auth::text, false);
  perform open_shift(n1, 1000);
  select id into v_sh from shifts where nozzle_id = n1 and closed_at is null;

  -- ---------------------------------------------------------------
  -- 1. another cashier still cannot
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_b_auth::text, false);
  v_res := close_shift(v_sh, 1100);
  if (v_res ->> 'message') <> 'that is not your shift' then
    raise exception 'a cashier closed somebody else''s pump: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 2. the manager can, and the reading is still checked
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_admin_auth::text, false);

  v_res := close_shift(v_sh, 900);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'an admin was allowed a meter below the opening one: %', v_res;
  end if;

  v_res := close_shift(v_sh, 1100);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'the manager could not close the pump: %', v_res;
  end if;
  if (v_res ->> 'message') <> 'shift closed for them' then
    raise exception 'closing for somebody else reads the same as closing your own: %', v_res;
  end if;

  -- The shift stays Abebe's - the manager took the reading, not the shift.
  if (select staff_id from shifts where id = v_sh) <> v_a then
    raise exception 'closing a shift moved it to the manager';
  end if;

  -- ---------------------------------------------------------------
  -- 3. the row says who closed it
  -- ---------------------------------------------------------------
  select closed_by_other into v_flag from list_shifts(null, 7, 200) where id = v_sh;
  if not v_flag then
    raise exception 'a shift closed by the manager does not say so';
  end if;

  -- And one closed by its own operator does not claim otherwise.
  perform set_config('test.uid', v_a_auth::text, false);
  perform open_shift(n2, 5000);
  select id into v_sh from shifts where nozzle_id = n2 and closed_at is null;
  perform close_shift(v_sh, 5100);

  select closed_by_other into v_flag from list_shifts(null, 7, 200) where id = v_sh;
  if v_flag then
    raise exception 'a normally closed shift was marked as closed by somebody else';
  end if;

  raise notice 'admin close: ok';
end $$;

-- ---------------------------------------------------------------
-- 4. shifts closed before 0017 existed
-- ---------------------------------------------------------------
-- They could only have been closed by their own operator, because that was
-- the only way. Backfilling closed_by keeps them from reading as manager
-- closures that never happened.
do $$
declare v_n int;
begin
  select count(*) into v_n from shifts
   where closed_at is not null and closed_by is null;
  if v_n <> 0 then
    raise exception '% closed shift(s) have no closed_by after the backfill', v_n;
  end if;
  raise notice 'backfill: ok';
end $$;
