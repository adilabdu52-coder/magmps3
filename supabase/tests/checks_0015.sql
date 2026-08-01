-- Checks for 0015: a forgotten check-out must not lock anyone out tomorrow,
-- and nothing may vanish from the manager's page.
--
--   psql -f supabase/tests/fixture.sql -f supabase/tests/auth_meta.sql \
--        -f supabase/migrations/0008_local_day.sql \
--        -f supabase/migrations/0015_shift_attendance_fixes.sql \
--        -f supabase/tests/checks_0015.sql

do $$
declare
  v_admin_auth uuid := gen_random_uuid();
  v_a_auth uuid := gen_random_uuid();
  v_nb_auth uuid := gen_random_uuid();
  v_a uuid; v_nb uuid; v_station uuid;
  v_res json;
  v_n int;
  v_id uuid;
begin
  insert into auth.users (id, email) values
    (v_admin_auth,'admin@x.com'), (v_a_auth,'a@x.com'), (v_nb_auth,'nb@x.com');
  insert into stations (name, town) values ('Adama','East Shewa') returning id into v_station;

  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_admin_auth,'Owner','admin','approved',null);
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_a_auth,'Abebe','operator','approved',v_station) returning id into v_a;
  -- Approved, but never given a branch.
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_nb_auth,'Hana','operator','approved',null) returning id into v_nb;

  -- ---------------------------------------------------------------
  -- 1. no branch: refuse, rather than write a row nobody will see
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_nb_auth::text, false);

  v_res := check_in();
  if (v_res ->> 'success') <> 'false' then
    raise exception 'someone with no branch was allowed to check in: %', v_res;
  end if;
  if (v_res ->> 'message') not like '%no branch%' then
    raise exception 'the refusal does not say why: %', v_res;
  end if;

  v_res := open_shift(1000);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'someone with no branch opened a shift: %', v_res;
  end if;

  if (select count(*) from attendance) <> 0 or (select count(*) from shifts) <> 0 then
    raise exception 'a row was written for someone with no branch';
  end if;

  -- ---------------------------------------------------------------
  -- 2. the forgotten check-out
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_a_auth::text, false);

  v_res := check_in();
  if (v_res ->> 'success') <> 'true' then raise exception 'a normal check-in failed: %', v_res; end if;

  v_res := check_in();
  if (v_res ->> 'message') <> 'already checked in today' then
    raise exception 'a second check-in on the same day was allowed: %', v_res;
  end if;

  -- Move it to three days ago: they went home and never checked out.
  update attendance set check_in = now() - interval '3 days'
   where staff_id = v_a and check_out is null;

  v_res := check_in();
  if (v_res ->> 'success') <> 'true' then
    raise exception 'a stale check-in still blocks today: %', v_res;
  end if;

  if (select count(*) from attendance where staff_id = v_a and abandoned) <> 1 then
    raise exception 'the old row was not marked abandoned';
  end if;
  if (select count(*) from attendance where staff_id = v_a
        and check_out is null and not abandoned) <> 1 then
    raise exception 'there should be exactly one live check-in';
  end if;

  -- An abandoned row must not be given an invented check-out. We do not know
  -- when that person went home, and a number here could settle a wage
  -- argument with a guess.
  if (select check_out from attendance where staff_id = v_a and abandoned) is not null then
    raise exception 'an abandoned row was given a made-up check-out time';
  end if;

  -- The cashier's own status must follow the live row, not the stale one.
  select id into v_id from my_attendance_status();
  if v_id <> (select id from attendance where staff_id = v_a and not abandoned) then
    raise exception 'the staff page is still looking at the abandoned row';
  end if;

  v_res := check_out();
  if (v_res ->> 'success') <> 'true' then raise exception 'check-out failed: %', v_res; end if;

  -- ---------------------------------------------------------------
  -- 3. the same, for shifts
  -- ---------------------------------------------------------------
  v_res := open_shift(1000);
  if (v_res ->> 'success') <> 'true' then raise exception 'opening a shift failed: %', v_res; end if;

  v_res := open_shift(1200);
  if (v_res ->> 'message') <> 'a shift is already open today' then
    raise exception 'two shifts were opened in one day: %', v_res;
  end if;

  update shifts set opened_at = now() - interval '2 days'
   where staff_id = v_a and closed_at is null;

  v_res := open_shift(1500);
  if (v_res ->> 'success') <> 'true' then
    raise exception 'a shift left open overnight still blocks today: %', v_res;
  end if;
  if (select closing_meter from shifts where staff_id = v_a and abandoned) is not null then
    raise exception 'an abandoned shift was given a made-up closing meter';
  end if;

  -- ---------------------------------------------------------------
  -- 4. a meter that goes backwards is a typo
  -- ---------------------------------------------------------------
  v_res := close_shift(1400);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'a closing meter below the opening one was accepted: %', v_res;
  end if;
  if (v_res ->> 'message') not like '%below the opening%' then
    raise exception 'unhelpful refusal: %', v_res;
  end if;

  v_res := close_shift(1600);
  if (v_res ->> 'success') <> 'true' then raise exception 'a valid close failed: %', v_res; end if;

  raise notice 'stale rows and meter guards: ok';
end $$;

-- ---------------------------------------------------------------
-- 5. nothing vanishes from the manager's page
-- ---------------------------------------------------------------
-- Rows written before 0015 can have a null station_id, and the old INNER JOIN
-- dropped them silently. That is the fault where the cashier saw "Checked in"
-- and the manager's page showed nobody.
do $$
declare
  v_admin_auth uuid; v_a uuid; v_n int;
begin
  select auth_user_id into v_admin_auth from staff where role = 'admin';
  select id into v_a from staff where full_name = 'Abebe';

  insert into attendance (station_id, staff_id, check_in)
  values (null, v_a, now() - interval '1 hour');
  insert into shifts (station_id, staff_id, opening_meter, opened_at)
  values (null, v_a, 500, now() - interval '1 hour');

  perform set_config('test.uid', v_admin_auth::text, false);

  select count(*) into v_n from list_attendance(null, 7, 200) where station_id is null;
  if v_n <> 1 then raise exception 'a branchless attendance row is invisible to the admin'; end if;

  select count(*) into v_n from list_shifts(null, 7, 200) where station_id is null;
  if v_n <> 1 then raise exception 'a branchless shift is invisible to the admin'; end if;

  if (select station_name from list_attendance(null, 7, 200) where station_id is null)
     <> '(no branch)' then
    raise exception 'a branchless row does not say so';
  end if;

  -- Hours must be null on an abandoned row rather than growing for ever.
  if (select hours from list_attendance(null, 7, 200) where abandoned limit 1) is not null then
    raise exception 'an abandoned row is still accumulating hours';
  end if;

  raise notice 'nothing vanishes: ok';
end $$;

-- ---------------------------------------------------------------
-- 6. an operator still sees only their own branch
-- ---------------------------------------------------------------
do $$
declare v_a_auth uuid; v_n int;
begin
  select auth_user_id into v_a_auth from staff where full_name = 'Abebe';
  perform set_config('test.uid', v_a_auth::text, false);

  -- The rewritten branch test must not have widened anything: a non-admin
  -- gets their own branch, and the branchless rows are not theirs to see.
  select count(*) into v_n from list_attendance(null, 7, 200) where station_id is null;
  if v_n <> 0 then raise exception 'an operator saw a branchless row'; end if;

  raise notice 'operator scoping: ok';
end $$;

-- ---------------------------------------------------------------
-- 7. the upgrade path
-- ---------------------------------------------------------------
-- The checks above were written against a schema that had never seen 0007,
-- so list_shifts did not exist and `create or replace` was free to define it
-- with whatever columns it liked. Every real database HAS 0007, and there
-- Postgres refuses:
--
--   ERROR: cannot change return type of existing function
--
-- That is how this shipped broken. The run script now loads 0007 before 0015
-- so this file exercises the path everybody actually takes, and these checks
-- confirm the new columns survived it.
do $$
declare v_admin_auth uuid; v_n int;
begin
  select auth_user_id into v_admin_auth from staff where role = 'admin';
  perform set_config('test.uid', v_admin_auth::text, false);

  -- If the drop had been skipped, list_shifts would still be 0007's version
  -- and this column would not exist.
  select count(*) into v_n from list_shifts(null, 7, 200) where abandoned is not null;
  if v_n = 0 then
    raise exception 'list_shifts has no abandoned column - the old definition survived';
  end if;

  select count(*) into v_n from list_attendance(null, 7, 200) where abandoned is not null;
  if v_n = 0 then
    raise exception 'list_attendance has no abandoned column - the old definition survived';
  end if;

  -- Dropping a function takes its grants with it.
  if not has_function_privilege('authenticated', 'list_shifts(uuid,int,int)', 'execute') then
    raise exception 'list_shifts lost its execute grant when it was recreated';
  end if;
  if not has_function_privilege('authenticated', 'list_attendance(uuid,int,int)', 'execute') then
    raise exception 'list_attendance lost its execute grant when it was recreated';
  end if;

  raise notice 'upgrade path: ok';
end $$;
