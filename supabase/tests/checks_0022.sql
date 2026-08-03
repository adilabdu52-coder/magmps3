-- Checks for 0022: a reset that leaves the tanks and the accounts right.
--
-- The whole point of this function is the arithmetic nobody does by hand, so
-- the checks are about the arithmetic. Every one of these is a way a manual
-- `delete from sales` gets it wrong.

do $$
declare
  v_admin uuid := gen_random_uuid();
  v_cash  uuid := gen_random_uuid();
  v_ad uuid; v_hi uuid; v_op uuid;
  v_t_d int; v_t_b int; v_t_hi int;
  v_cust uuid; v_n1 uuid;
  v_today date; v_res json; v_n int; v_stock numeric; v_bal numeric;
begin
  insert into auth.users (id, email) values (v_admin,'ad@x.com'), (v_cash,'c@x.com');
  insert into stations (name) values ('Adama') returning id into v_ad;
  insert into stations (name) values ('Hirna') returning id into v_hi;

  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_admin,'Owner','admin','approved',null)
  on conflict (auth_user_id) do update set role = excluded.role, status = excluded.status;
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_cash,'Abebe','operator','approved',v_ad)
  on conflict (auth_user_id) do update
    set role = excluded.role, status = excluded.status, station_id = excluded.station_id
  returning id into v_op;

  insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
  values (v_ad,'D1','Diesel', 50000, 10000) returning id into v_t_d;
  insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
  values (v_ad,'B1','Benzil', 50000, 20000) returning id into v_t_b;
  insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters)
  values (v_hi,'D1','Diesel', 50000, 30000) returning id into v_t_hi;

  insert into credit_customers (station_id, name, balance)
  values (v_ad,'Dashen Transport', 8000) returning id into v_cust;

  insert into nozzles (station_id, label, fuel_type) values (v_ad,'Pump 1','Diesel')
    returning id into v_n1;

  v_today := (now() at time zone app_timezone())::date;

  insert into sales (station_id, staff_id, nozzle_id, fuel_type, liters, total_etb,
                     payment_method, credit_customer_id, voided, created_at)
  values
    -- live cash at Adama: 500 L must go back
    (v_ad, v_op, v_n1, 'Diesel', 500, 50000, 'cash',   null,  false, now()),
    -- live credit at Adama: 200 L back AND 20,000 off the account
    (v_ad, v_op, v_n1, 'Diesel', 200, 20000, 'credit', v_cust, false, now()),
    -- ALREADY VOIDED: its litres and its credit went back at the void, so
    -- this row must be deleted WITHOUT being reversed a second time
    (v_ad, v_op, v_n1, 'Diesel', 900, 90000, 'credit', v_cust, true,  now()),
    -- another branch, to prove the branch filter
    (v_hi, v_op, null, 'Diesel', 300, 30000, 'cash',   null,  false, now()),
    -- outside the range, to prove the date filter: this must survive
    (v_ad, v_op, v_n1, 'Benzil', 400, 36000, 'cash',   null,  false,
     now() - interval '10 days');

  -- Only one may be open on a pump at a time (0016), so the older one is
  -- closed - which is what a shift from ten days ago would be anyway.
  insert into shifts (station_id, staff_id, nozzle_id, opening_meter, opened_at)
  values (v_ad, v_op, v_n1, 1000, now());
  insert into shifts (station_id, staff_id, nozzle_id, opening_meter, opened_at,
                      closing_meter, closed_at)
  values (v_ad, v_op, v_n1, 2000, now() - interval '10 days',
          2100, now() - interval '10 days' + interval '8 hours');
  insert into attendance (station_id, staff_id, check_in)
  values (v_ad, v_op, now());
  insert into expenses (station_id, category, description, amount_etb)
  values (v_ad, 'fuel', 'test', 100);
  insert into deliveries (station_id, tank_id, liters, note)
  values (v_ad, v_t_b, 5000, 'test delivery');
  insert into sale_corrections (sale_id, station_id, reported_by, reason)
  values ((select id from sales where liters = 500), v_ad, v_op, 'test');

  -- ---------------------------------------------------------------
  -- 1. a cashier cannot reset anything
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_cash::text, false);
  v_res := admin_reset_transactions(v_today, v_today, null, 'RESET');
  if (v_res ->> 'success') <> 'false' then
    raise exception 'a cashier reset the database: %', v_res;
  end if;
  if exists (select 1 from sales where liters = 500) is false then
    raise exception 'the refusal still deleted something';
  end if;

  perform set_config('test.uid', v_admin::text, false);

  -- ---------------------------------------------------------------
  -- 2. it will not fire without the word
  -- ---------------------------------------------------------------
  -- Everything this does is permanent. It must not be reachable by
  -- mistyping a date or clicking the wrong button.
  v_res := admin_reset_transactions(v_today, v_today, null, null);
  if (v_res ->> 'success') <> 'false' then raise exception 'reset ran with no confirmation'; end if;
  v_res := admin_reset_transactions(v_today, v_today, null, 'reset');
  if (v_res ->> 'success') <> 'false' then raise exception 'lowercase confirmed the reset'; end if;
  v_res := admin_reset_transactions(null, v_today, null, 'RESET');
  if (v_res ->> 'success') <> 'false' then raise exception 'an open-ended range was accepted'; end if;
  v_res := admin_reset_transactions(v_today, v_today - 5, null, 'RESET');
  if (v_res ->> 'success') <> 'false' then raise exception 'a backwards range was accepted'; end if;

  select count(*) into v_n from sales;
  if v_n <> 5 then raise exception 'a refused reset deleted % of the 5 sales', 5 - v_n; end if;

  -- ---------------------------------------------------------------
  -- 3. the preview changes nothing
  -- ---------------------------------------------------------------
  v_res := admin_reset_preview(v_today, v_today, null);
  if (v_res ->> 'sales')::int <> 4 then
    raise exception 'the preview counts % sales not 4', v_res ->> 'sales';
  end if;
  if (v_res ->> 'voided_sales')::int <> 1 then
    raise exception 'the preview counts % voided not 1', v_res ->> 'voided_sales';
  end if;
  select count(*) into v_n from sales;
  if v_n <> 5 then raise exception 'the preview deleted something'; end if;
  select current_liters into v_stock from tanks where id = v_t_d;
  if v_stock <> 10000 then raise exception 'the preview moved a tank'; end if;

  -- ---------------------------------------------------------------
  -- 4. the reset itself
  -- ---------------------------------------------------------------
  v_res := admin_reset_transactions(v_today, v_today, null, 'RESET');
  if (v_res ->> 'success') <> 'true' then raise exception 'the reset failed: %', v_res; end if;
  if (v_res ->> 'sales')::int <> 4 then
    raise exception 'it removed % sales not 4', v_res ->> 'sales';
  end if;

  -- THE POINT OF THE WHOLE FUNCTION.
  -- Adama Diesel: 500 + 200 live back = 10,700. The voided 900 must NOT be
  -- added - admin_void_sale already put those litres back at the void, and
  -- adding them again would invent fuel out of nothing.
  select current_liters into v_stock from tanks where id = v_t_d;
  if v_stock <> 10700 then
    raise exception 'Adama diesel reads % - expected 10,700 (900 voided litres double-counted?)',
      v_stock;
  end if;

  -- Hirna is a different branch and gets its own 300 back.
  select current_liters into v_stock from tanks where id = v_t_hi;
  if v_stock <> 30300 then raise exception 'Hirna diesel reads % not 30,300', v_stock; end if;

  -- Benzil: nothing sold in range, but a 5,000 L delivery was deleted, and a
  -- delivery put fuel IN - so removing it takes that fuel back out.
  select current_liters into v_stock from tanks where id = v_t_b;
  if v_stock <> 15000 then
    raise exception 'Benzil reads % not 15,000 - was the delivery reversed?', v_stock;
  end if;

  -- Credit: 20,000 off the live credit sale only. The voided 90,000 came off
  -- at the void, so 8,000 - 20,000 floors at zero rather than going negative.
  select balance into v_bal from credit_customers where id = v_cust;
  if v_bal <> 0 then raise exception 'the balance reads % not 0', v_bal; end if;
  if (v_res ->> 'credit_cleared')::numeric <> 20000 then
    raise exception 'it reports % ETB of credit not 20,000', v_res ->> 'credit_cleared';
  end if;

  -- ---------------------------------------------------------------
  -- 5. what it must NOT have touched
  -- ---------------------------------------------------------------
  -- The date filter: the Benzil sale and the shift from ten days ago are
  -- real trade as far as this reset is concerned.
  if not exists (select 1 from sales where liters = 400) then
    raise exception 'it deleted a sale outside the range';
  end if;
  select count(*) into v_n from shifts;
  if v_n <> 1 then raise exception 'shifts outside the range were deleted'; end if;

  -- The setup survives. Losing any of this means building it all again.
  if (select count(*) from stations) <> 2 then raise exception 'it deleted a branch'; end if;
  if (select count(*) from staff) < 2 then raise exception 'it deleted staff'; end if;
  if (select count(*) from tanks) <> 3 then raise exception 'it deleted a tank'; end if;
  if (select count(*) from nozzles) <> 1 then raise exception 'it deleted a pump'; end if;
  if (select count(*) from credit_customers) <> 1 then
    raise exception 'it deleted a credit customer';
  end if;

  -- And the rows with no side effects went.
  if (select count(*) from attendance) <> 0 then raise exception 'attendance survived'; end if;
  if (select count(*) from expenses) <> 0 then raise exception 'expenses survived'; end if;
  if (select count(*) from deliveries) <> 0 then raise exception 'deliveries survived'; end if;
  if (select count(*) from sale_corrections) <> 0 then
    raise exception 'a correction survived, pointing at a sale that is gone';
  end if;

  -- ---------------------------------------------------------------
  -- 6. it writes down that it happened
  -- ---------------------------------------------------------------
  -- In a year somebody will ask why the figures start where they do.
  if not exists (select 1 from branch_notes where body like 'Data reset:%') then
    raise exception 'the reset left no record of itself';
  end if;

  -- ---------------------------------------------------------------
  -- 7. one branch only
  -- ---------------------------------------------------------------
  insert into sales (station_id, staff_id, fuel_type, liters, total_etb,
                     payment_method, voided, created_at)
  values (v_ad, v_op, 'Diesel', 50, 5000, 'cash', false, now()),
         (v_hi, v_op, 'Diesel', 70, 7000, 'cash', false, now());

  v_res := admin_reset_transactions(v_today, v_today, v_hi, 'RESET');
  if (v_res ->> 'sales')::int <> 1 then
    raise exception 'a one-branch reset took % sales not 1', v_res ->> 'sales';
  end if;
  if not exists (select 1 from sales where station_id = v_ad and liters = 50) then
    raise exception 'resetting Hirna deleted an Adama sale';
  end if;
  select current_liters into v_stock from tanks where id = v_t_hi;
  if v_stock <> 30370 then raise exception 'Hirna diesel reads % not 30,370', v_stock; end if;

  -- ---------------------------------------------------------------
  -- 8. a tank pushed over its capacity is reported, not hidden
  -- ---------------------------------------------------------------
  -- A reading above what the tank holds is visibly wrong and gets fixed; a
  -- number quietly trimmed to fit looks right and stays wrong.
  update tanks set current_liters = 49900 where id = v_t_hi;
  insert into sales (station_id, staff_id, fuel_type, liters, total_etb,
                     payment_method, voided, created_at)
  values (v_hi, v_op, 'Diesel', 500, 50000, 'cash', false, now());

  v_res := admin_reset_transactions(v_today, v_today, v_hi, 'RESET');
  if jsonb_array_length((v_res -> 'over_capacity')::jsonb) <> 1 then
    raise exception 'a tank over capacity was not reported: %', v_res -> 'over_capacity';
  end if;
  select current_liters into v_stock from tanks where id = v_t_hi;
  if v_stock <> 50400 then
    raise exception 'the tank reads % - was it silently trimmed to capacity?', v_stock;
  end if;

  -- ---------------------------------------------------------------
  -- 9. fuel with nowhere to go is reported too
  -- ---------------------------------------------------------------
  -- Those litres are unaccounted for and somebody has to know.
  insert into sales (station_id, staff_id, fuel_type, liters, total_etb,
                     payment_method, voided, created_at)
  values (v_hi, v_op, 'Kerosene', 80, 8000, 'cash', false, now());

  v_res := admin_reset_transactions(v_today, v_today, v_hi, 'RESET');
  if jsonb_array_length((v_res -> 'no_tank_for')::jsonb) <> 1 then
    raise exception 'fuel with no tank was dropped silently: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 10. just delete it, leave the tanks alone
  -- ---------------------------------------------------------------
  -- The honest option when the manager is about to dip the tanks anyway:
  -- the restored figure would be overwritten within the minute, and putting
  -- it there first only risks a spurious over-capacity warning.
  update tanks set current_liters = 20000 where id = v_t_hi;
  update credit_customers set balance = 5000 where id = v_cust;
  insert into sales (station_id, staff_id, fuel_type, liters, total_etb,
                     payment_method, credit_customer_id, voided, created_at)
  values (v_hi, v_op, 'Diesel', 600, 60000, 'cash', null, false, now()),
         (v_hi, v_op, 'Diesel', 100, 10000, 'credit', v_cust, false, now());
  insert into deliveries (station_id, tank_id, liters, note)
  values (v_hi, v_t_hi, 3000, 'test delivery');

  v_res := admin_reset_transactions(v_today, v_today, v_hi, 'RESET', false);
  if (v_res ->> 'success') <> 'true' then raise exception 'the plain reset failed: %', v_res; end if;
  if (v_res ->> 'sales')::int <> 2 then
    raise exception 'it removed % sales not 2', v_res ->> 'sales';
  end if;
  if (v_res ->> 'deliveries')::int <> 1 then raise exception 'the delivery survived'; end if;

  -- The rows are gone and NOTHING was moved.
  select current_liters into v_stock from tanks where id = v_t_hi;
  if v_stock <> 20000 then
    raise exception 'p_restore false still moved the tank: % not 20,000', v_stock;
  end if;
  select balance into v_bal from credit_customers where id = v_cust;
  if v_bal <> 5000 then
    raise exception 'p_restore false still touched the balance: % not 5,000', v_bal;
  end if;
  if (v_res ->> 'liters_returned')::numeric <> 0 then
    raise exception 'it claims to have returned % L', v_res ->> 'liters_returned';
  end if;

  -- ---------------------------------------------------------------
  -- 11. saying what is actually in the tank
  -- ---------------------------------------------------------------
  -- The one number that is a measurement rather than a calculation. Before
  -- this, a manager whose tank read wrong had to record a delivery that
  -- never arrived - fixing the figure and putting a lie in the history.
  v_res := admin_set_tank_level(v_t_hi, 12400, 'dipped after the reset');
  if (v_res ->> 'success') <> 'true' then raise exception 'setting the level failed: %', v_res; end if;
  select current_liters into v_stock from tanks where id = v_t_hi;
  if v_stock <> 12400 then raise exception 'the tank reads % not 12,400', v_stock; end if;
  if (v_res ->> 'was')::numeric <> 20000 then
    raise exception 'it reports the old level as %', v_res ->> 'was';
  end if;

  -- A stick cannot read more than the tank holds, so that is a typo. Letting
  -- it through makes every stock percentage on the dashboard nonsense.
  v_res := admin_set_tank_level(v_t_hi, 999999, null);
  if (v_res ->> 'success') <> 'false' then raise exception 'a tank was overfilled: %', v_res; end if;
  v_res := admin_set_tank_level(v_t_hi, -5, null);
  if (v_res ->> 'success') <> 'false' then raise exception 'a negative level was accepted'; end if;
  select current_liters into v_stock from tanks where id = v_t_hi;
  if v_stock <> 12400 then raise exception 'a refused level still changed the tank'; end if;

  -- A stock figure that changed by hand and left no trace is
  -- indistinguishable from one that drifted.
  if not exists (select 1 from branch_notes where body like 'Tank level set by hand:%') then
    raise exception 'setting a level by hand left no record';
  end if;

  perform set_config('test.uid', v_cash::text, false);
  v_res := admin_set_tank_level(v_t_hi, 1, null);
  if (v_res ->> 'success') <> 'false' then raise exception 'a cashier set a tank level'; end if;
  perform set_config('test.uid', v_admin::text, false);

  raise notice 'reset: ok';
end $$;
