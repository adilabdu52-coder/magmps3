-- Checks for 0011: a write that changed nothing must not report success.
--
--   psql -f supabase/tests/fixture.sql -f supabase/tests/auth_meta.sql \
--        -f supabase/migrations/0011_report_zero_row_writes.sql \
--        -f supabase/tests/checks_0011.sql
--
-- Every check raises on failure, so a clean run is a pass.

do $$
declare
  v_admin_auth uuid := gen_random_uuid();
  v_op_auth    uuid := gen_random_uuid();
  v_admin      uuid;
  v_op         uuid;
  v_station    uuid;
  v_cust       uuid;
  v_missing    uuid := '00000000-0000-0000-0000-000000000000';
  v_res        json;
  v_status     text;
  v_balance    numeric;
begin
  insert into auth.users (id, email) values (v_admin_auth, 'admin@example.com'),
                                            (v_op_auth,    'op@example.com');
  insert into stations (name, town) values ('Adama', 'East Shewa') returning id into v_station;

  insert into staff (auth_user_id, full_name, email, role, status)
  values (v_admin_auth, 'Owner', 'admin@example.com', 'admin', 'approved')
  returning id into v_admin;

  insert into staff (auth_user_id, full_name, email, role, status)
  values (v_op_auth, 'Abebe Kebede', 'op@example.com', 'operator', 'pending')
  returning id into v_op;

  insert into credit_customers (station_id, name, balance)
  values (v_station, 'Garage Ltd', 500) returning id into v_cust;

  -- Act as the admin from here.
  perform set_config('test.uid', v_admin_auth::text, false);

  -- ---------------------------------------------------------------
  -- 1. the bug: an id that matches nothing
  -- ---------------------------------------------------------------
  v_res := admin_set_staff_status(v_missing, 'approved');
  if (v_res ->> 'success') <> 'false' then
    raise exception 'status: a missing id still reported success: %', v_res;
  end if;
  if (v_res ->> 'message') not like '%no such staff%' then
    raise exception 'status: unhelpful message for a missing id: %', v_res;
  end if;

  v_res := admin_set_staff_role(v_missing, 'operator');
  if (v_res ->> 'success') <> 'false' then
    raise exception 'role: a missing id still reported success: %', v_res;
  end if;

  v_res := admin_set_staff_station(v_missing, v_station);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'station: a missing id still reported success: %', v_res;
  end if;

  v_res := admin_credit_payment(v_missing, 100);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'credit: a missing customer still reported success: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 2. the normal path still works
  -- ---------------------------------------------------------------
  v_res := admin_set_staff_status(v_op, 'approved');
  if (v_res ->> 'success') <> 'true' then
    raise exception 'status: refused a real staff id: %', v_res;
  end if;
  select status into v_status from staff where id = v_op;
  if v_status <> 'approved' then raise exception 'status did not change: %', v_status; end if;

  v_res := admin_set_staff_station(v_op, v_station);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'station: refused a real assignment: %', v_res;
  end if;
  if (select station_id from staff where id = v_op) is null then
    raise exception 'branch was not assigned';
  end if;

  -- Clearing a branch is legitimate: it is how a central admin sees all five.
  v_res := admin_set_staff_station(v_op, null);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'station: refused a deliberate clear: %', v_res;
  end if;
  if (select station_id from staff where id = v_op) is not null then
    raise exception 'branch was not cleared';
  end if;

  -- A branch that does not exist is an error, not a silent clear. Without
  -- this check a mistyped id would look exactly like "no branch".
  v_res := admin_set_staff_station(v_op, v_missing);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'station: accepted a branch that does not exist: %', v_res;
  end if;

  v_res := admin_credit_payment(v_cust, 200);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'credit: refused a real payment: %', v_res;
  end if;
  select balance into v_balance from credit_customers where id = v_cust;
  if v_balance <> 300 then raise exception 'balance is %, expected 300', v_balance; end if;

  -- ---------------------------------------------------------------
  -- 3. the guards that were already there still hold
  -- ---------------------------------------------------------------
  v_res := admin_set_staff_status(v_op, 'nonsense');
  if (v_res ->> 'message') <> 'unknown status' then
    raise exception 'a bad status was not rejected: %', v_res;
  end if;

  -- Owner is the only approved admin, so demoting them must be refused - and
  -- refused for THAT reason, not because the row was missing.
  v_res := admin_set_staff_role(v_admin, 'operator');
  if (v_res ->> 'message') <> 'cannot remove the last admin' then
    raise exception 'the last admin was not protected: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 4. a non-admin gets nowhere
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_op_auth::text, false);
  v_res := admin_set_staff_status(v_admin, 'rejected');
  if (v_res ->> 'message') <> 'not authorised' then
    raise exception 'an operator was allowed to set status: %', v_res;
  end if;
  if (select status from staff where id = v_admin) <> 'approved' then
    raise exception 'an operator changed the admin''s status';
  end if;

  raise notice 'zero-row writes are reported honestly: ok';
end $$;
