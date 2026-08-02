-- Checks for 0020: a stale shift stops blocking the till, and two pumps at
-- once keeps working.

do $$
declare
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_op uuid; v_other uuid; v_s uuid;
  v_n1 uuid; v_n2 uuid; v_n3 uuid;
  v_dead uuid; v_yday uuid;
  v_res json; v_n int;
begin
  insert into auth.users (id, email) values (v_a,'a@x.com'), (v_b,'b@x.com');
  insert into stations (name) values ('Adama') returning id into v_s;
  insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
  values (v_s, 'T1', 'Diesel', 50000, 40000);
  insert into fuel_prices (station_id, fuel_type, price_per_liter) values (v_s,'Diesel',100);

  -- 0010's trigger may already have made these rows from the auth.users
  -- insert above. Upsert so this file passes whether or not it is loaded.
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_a,'Ehab','operator','approved',v_s)
  on conflict (auth_user_id) do update
    set full_name = excluded.full_name, role = excluded.role,
        status = excluded.status, station_id = excluded.station_id
  returning id into v_op;
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_b,'Nasir','operator','approved',v_s)
  on conflict (auth_user_id) do update
    set full_name = excluded.full_name, role = excluded.role,
        status = excluded.status, station_id = excluded.station_id
  returning id into v_other;

  insert into nozzles (station_id, label, fuel_type) values (v_s,'Pump 1','Diesel')
    returning id into v_n1;
  insert into nozzles (station_id, label, fuel_type) values (v_s,'Pump 2','Diesel')
    returning id into v_n2;
  insert into nozzles (station_id, label, fuel_type) values (v_s,'Pump 3','Diesel')
    returning id into v_n3;

  -- ---------------------------------------------------------------
  -- 1. the row 0020 was written for
  -- ---------------------------------------------------------------
  -- Exactly what is in the live data: opened before nozzles existed, so no
  -- nozzle, and open ever since. The migration's own update ran before this
  -- row was made, so 0020's other two parts have to hold it.
  insert into shifts (station_id, staff_id, opening_meter, opened_at)
  values (v_s, v_op, 1000, now() - interval '2 days') returning id into v_dead;

  perform set_config('test.uid', v_a::text, false);

  select count(*) into v_n from my_open_shifts();
  if v_n <> 0 then
    raise exception 'a shift with no nozzle is still offered to the till (% rows)', v_n;
  end if;

  -- ---------------------------------------------------------------
  -- 2. and it no longer stands between them and a pump
  -- ---------------------------------------------------------------
  v_res := open_shift(v_n1, 500);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'the dead row blocked a new shift: %', v_res;
  end if;
  if not (select abandoned from shifts where id = v_dead) then
    raise exception 'the dead row was not swept';
  end if;

  -- The sale that was refused before now goes through.
  v_res := record_sale(v_n1, 20, 'cash', null);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'the sale still will not save: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 3. two pumps at once still works - this is the point of 0016
  -- ---------------------------------------------------------------
  -- The sweep must only reach BACK. A person on Pump 1 and Pump 4 at the
  -- same time is the ordinary working day, and abandoning one of those to
  -- open the other would break the feature this fixes.
  v_res := open_shift(v_n2, 700);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'a second pump was refused: %', v_res;
  end if;

  select count(*) into v_n from my_open_shifts();
  if v_n <> 2 then raise exception 'two pumps open reads as % shift(s)', v_n; end if;

  -- Today's own shift is not swept by opening another today.
  if exists (select 1 from shifts
              where staff_id = v_op and nozzle_id = v_n1 and abandoned) then
    raise exception 'opening a second pump abandoned the first';
  end if;

  -- ---------------------------------------------------------------
  -- 4. yesterday's shift on a pump nobody is reopening
  -- ---------------------------------------------------------------
  -- 0016 only ever swept the nozzle being opened, so a shift left open on
  -- Pump 3 stayed open for ever unless somebody happened to open Pump 3.
  insert into shifts (station_id, staff_id, nozzle_id, opening_meter, opened_at)
  values (v_s, v_other, v_n3, 900, now() - interval '1 day') returning id into v_yday;

  perform set_config('test.uid', v_b::text, false);
  v_res := open_shift(v_n1, 600);
  -- Pump 1 is Ehab's today, so this is refused - but the sweep runs first,
  -- and Nasir's own forgotten Pump 3 should be gone regardless.
  if (v_res ->> 'success') <> 'false' then
    raise exception 'somebody else got onto an occupied pump: %', v_res;
  end if;
  if not (select abandoned from shifts where id = v_yday) then
    raise exception 'yesterday''s shift on another pump was not swept';
  end if;

  -- ---------------------------------------------------------------
  -- 5. the manager can still see it happened
  -- ---------------------------------------------------------------
  -- Abandoned, not deleted. A day that went unrecorded is a fact worth
  -- keeping; quietly removing the row would hide it.
  perform set_config('test.uid', v_a::text, false);
  update staff set role = 'admin' where id = v_op;
  if not exists (select 1 from list_shifts(null, 7, 200) where abandoned) then
    raise exception 'a swept shift vanished from the manager''s list';
  end if;

  raise notice '0020 checks passed';
end $$;
