-- Checks for 0019: a note can carry a shift record, and the figures add up.

do $$
declare
  v_admin_auth uuid := gen_random_uuid();
  v_op_auth uuid := gen_random_uuid();
  v_op uuid; v_s uuid; v_noz uuid; v_res json; r record;
begin
  insert into auth.users (id, email) values (v_admin_auth,'ad@x.com'), (v_op_auth,'o@x.com');
  insert into stations (name) values ('Adama') returning id into v_s;
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_admin_auth,'Owner','admin','approved',null);
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_op_auth,'Abebe','operator','approved',v_s) returning id into v_op;
  insert into nozzles (station_id, label, fuel_type)
  values (v_s,'Pump 1','Diesel') returning id into v_noz;

  perform set_config('test.uid', v_admin_auth::text, false);

  -- ---------------------------------------------------------------
  -- 1. a full shift record
  -- ---------------------------------------------------------------
  v_res := admin_add_note('Morning shift', v_s, false, v_op, v_noz, 1000, 1180,
                          '{"Diesel": 120, "Benzil": 60}'::jsonb);
  if (v_res ->> 'success') <> 'true' then raise exception 'a shift note failed: %', v_res; end if;

  select * into r from admin_list_notes(null, 100) where staff_name is not null;
  if r.staff_name <> 'Abebe' then raise exception 'the person was not recorded: %', r.staff_name; end if;
  if r.nozzle_label <> 'Pump 1' then raise exception 'the pump was not recorded'; end if;
  if r.metered_liters <> 180 then raise exception 'metered is % not 180', r.metered_liters; end if;
  -- 120 + 60. When this disagrees with the meter, the manager's own
  -- arithmetic is worth a look before anybody else's.
  if r.noted_liters <> 180 then raise exception 'the fuels add to % not 180', r.noted_liters; end if;

  -- ---------------------------------------------------------------
  -- 2. a meter that runs backwards is a slip
  -- ---------------------------------------------------------------
  v_res := admin_add_note('bad', v_s, false, v_op, v_noz, 1200, 1100, null);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'an end reading below the start was accepted: %', v_res;
  end if;
  if (v_res ->> 'message') not like '%below the start%' then
    raise exception 'unhelpful refusal: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 3. a plain sentence still works
  -- ---------------------------------------------------------------
  -- Most notes will be one. Requiring the figures would make the notebook
  -- useless for the thing it was built for.
  v_res := admin_add_note('Tank 3 gauge reads low', v_s, false, null, null, null, null, null);
  if (v_res ->> 'success') <> 'true' then raise exception 'a plain note failed: %', v_res; end if;

  -- Figures with no sentence work too - a record does not need prose.
  v_res := admin_add_note('', v_s, false, v_op, v_noz, 2000, 2050, null);
  if (v_res ->> 'success') <> 'true' then raise exception 'a figures-only note failed: %', v_res; end if;

  -- Nothing at all is still nothing.
  v_res := admin_add_note('  ', v_s, false, null, null, null, null, null);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'an entirely empty note was saved: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 4. references are checked
  -- ---------------------------------------------------------------
  v_res := admin_add_note('x', v_s, false,
             '00000000-0000-0000-0000-000000000000'::uuid, null, null, null, null);
  if (v_res ->> 'message') <> 'no such staff member' then
    raise exception 'a note named a staff member who does not exist: %', v_res;
  end if;

  v_res := admin_add_note('x', v_s, false, null,
             '00000000-0000-0000-0000-000000000000'::uuid, null, null, null);
  if (v_res ->> 'message') <> 'no such pump' then
    raise exception 'a note named a pump that does not exist: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 5. still admin only
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_op_auth::text, false);
  v_res := admin_add_note('sneaky', v_s, false, null, null, null, null, null);
  if (v_res ->> 'message') <> 'not authorised' then
    raise exception 'a cashier wrote a note: %', v_res;
  end if;
  if (select count(*) from admin_list_notes(null, 100)) <> 0 then
    raise exception 'a cashier read the notebook';
  end if;

  raise notice 'shift records in notes: ok';
end $$;
