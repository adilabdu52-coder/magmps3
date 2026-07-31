-- Checks for 0010: the staff row must appear whenever a login appears.
--
-- Run against the fixture, which stands in for the schema after 0001-0006:
--
--   psql -f supabase/tests/fixture.sql -f supabase/tests/auth_meta.sql \
--        -f supabase/migrations/0010_signup_trigger.sql \
--        -f supabase/tests/checks_0010.sql
--
-- Every check raises an exception on failure, so a clean run means a pass.

do $$
declare
  v_uid   uuid := gen_random_uuid();
  v_name  text;
  v_phone text;
  v_role  text;
  v_stat  text;
  v_n     int;
begin
  -- ---------------------------------------------------------------
  -- 1. a signup carrying name and phone
  -- ---------------------------------------------------------------
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_uid, 'abebe@example.com',
          '{"full_name":"Abebe Kebede","phone":"0912345678"}'::jsonb);

  select full_name, phone, role, status into v_name, v_phone, v_role, v_stat
    from staff where auth_user_id = v_uid;

  if v_name is null then
    raise exception 'no staff row was created for a new login';
  end if;
  if v_name <> 'Abebe Kebede' then raise exception 'name not carried across: %', v_name; end if;
  if v_phone <> '0912345678'   then raise exception 'phone not carried across: %', v_phone; end if;

  -- Never admin, never approved. A trigger that could mint an approved admin
  -- would turn "anyone may sign up" into "anyone may take the till".
  if v_role <> 'operator' then raise exception 'new signup got role %', v_role; end if;
  if v_stat <> 'pending'  then raise exception 'new signup got status %', v_stat; end if;

  -- ---------------------------------------------------------------
  -- 2. a signup with no metadata at all
  -- ---------------------------------------------------------------
  -- An older build of the app sends none. The row must still appear: a
  -- nameless row in the staff list is visible and fixable, a missing one is
  -- neither.
  v_uid := gen_random_uuid();
  insert into auth.users (id, email) values (v_uid, 'noname@example.com');

  select count(*) into v_n from staff where auth_user_id = v_uid;
  if v_n <> 1 then raise exception 'no staff row when metadata was absent'; end if;

  select full_name into v_name from staff where auth_user_id = v_uid;
  if v_name is not null then raise exception 'blank name stored as % not null', v_name; end if;

  -- ---------------------------------------------------------------
  -- 3. blank strings are not names
  -- ---------------------------------------------------------------
  v_uid := gen_random_uuid();
  insert into auth.users (id, email, raw_user_meta_data)
  values (v_uid, 'blank@example.com', '{"full_name":"   ","phone":""}'::jsonb);

  select full_name, phone into v_name, v_phone from staff where auth_user_id = v_uid;
  if v_name is not null  then raise exception 'whitespace name stored as "%"', v_name; end if;
  if v_phone is not null then raise exception 'empty phone stored as "%"', v_phone; end if;

  raise notice 'trigger: ok';
end $$;

-- ---------------------------------------------------------------
-- 4. the trigger must never break signup
-- ---------------------------------------------------------------
-- If handle_new_auth_user raises, it does so inside Supabase's signup
-- transaction and the login is rolled back with it. An account with no staff
-- row can be repaired by hand; an account that was never created cannot.
-- Force a failure and confirm the login survives it.
alter table staff add constraint staff_break_trigger check (email <> 'boom@example.com');

do $$
declare v_uid uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v_uid, 'boom@example.com');

  if not exists (select 1 from auth.users where id = v_uid) then
    raise exception 'a failing trigger rolled back the login itself';
  end if;
  if exists (select 1 from staff where auth_user_id = v_uid) then
    raise exception 'the staff row was created despite the constraint';
  end if;

  raise notice 'trigger failure is survivable: ok';
end $$;

alter table staff drop constraint staff_break_trigger;

-- ---------------------------------------------------------------
-- 5. register_staff fills in what the trigger could not
-- ---------------------------------------------------------------
do $$
declare
  v_uid  uuid := gen_random_uuid();
  v_res  json;
  v_name text;
  v_n    int;
begin
  insert into auth.users (id, email) values (v_uid, 'late@example.com');
  perform set_config('test.uid', v_uid::text, false);

  v_res := register_staff('Chaltu Bekele', '0911111111');
  if (v_res ->> 'success') <> 'true' then
    raise exception 'register_staff refused a valid call: %', v_res;
  end if;

  select full_name into v_name from staff where auth_user_id = v_uid;
  if v_name <> 'Chaltu Bekele' then raise exception 'name not filled in: %', v_name; end if;

  -- It must not make a second row for the same person.
  select count(*) into v_n from staff where auth_user_id = v_uid;
  if v_n <> 1 then raise exception 'register_staff created % rows', v_n; end if;

  -- Called again with nothing, it must not erase what is there. A person who
  -- submits an empty form should not lose their name.
  v_res := register_staff('', '');
  select full_name into v_name from staff where auth_user_id = v_uid;
  if v_name <> 'Chaltu Bekele' then raise exception 'a blank submission erased the name'; end if;

  raise notice 'register_staff top-up: ok';
end $$;

-- ---------------------------------------------------------------
-- 6. register_staff without a session
-- ---------------------------------------------------------------
do $$
declare v_res json;
begin
  perform set_config('test.uid', '', false);
  v_res := register_staff('Nobody', null);

  if (v_res ->> 'success') <> 'false' then
    raise exception 'register_staff accepted a call with no session: %', v_res;
  end if;
  if (v_res ->> 'message') <> 'not authenticated' then
    raise exception 'unexpected refusal wording: %', v_res;
  end if;

  raise notice 'no-session refusal: ok';
end $$;

-- ---------------------------------------------------------------
-- 7. the invariant, stated once
-- ---------------------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n
    from auth.users u
   where u.email <> 'boom@example.com'
     and not exists (select 1 from staff s where s.auth_user_id = u.id);

  if v_n <> 0 then raise exception '% login(s) have no staff row', v_n; end if;
  raise notice 'every login has a staff row: ok';
end $$;
