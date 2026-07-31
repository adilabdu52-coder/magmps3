-- 0010 — create the staff row in the database, not in the browser
--
-- Until now, signing up took two steps that had to both succeed: Supabase
-- created the login, then the browser called register_staff() to create the
-- staff row. The second step needs auth.uid(), which needs a session, and
-- signUp only returns a session when the project does NOT ask for e-mail
-- confirmation.
--
-- So a single setting on a dashboard page decided whether new accounts worked
-- at all. Turn on "Confirm email" and every signup produces a login with no
-- staff row: the person waits to be approved, and the manager sees nobody to
-- approve. This cost a working day and two people's accounts before anyone
-- could see what was happening, because the failure looked like success.
--
-- Nothing about that is the setting's fault. The design was wrong: account
-- creation should not depend on the browser being handed a session, because
-- whether it is handed one is not the browser's decision.
--
-- After this, the database does it. A trigger on auth.users creates the staff
-- row the moment the login exists - session or no session, confirmation on or
-- off. register_staff stays, because the app still calls it and it is still
-- the only thing that knows the person's name and phone, but it is no longer
-- what stands between a signup and an account.

begin;

-- ---------------------------------------------------------------
-- the trigger function
-- ---------------------------------------------------------------
-- The name and phone arrive in raw_user_meta_data, which is what
-- signUp({ options: { data } }) writes. They are whatever the person typed,
-- so treat them as untrusted input: trim them, and turn blank into null
-- rather than storing an empty string that later reads as a name.
create or replace function handle_new_auth_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.staff (auth_user_id, full_name, phone, email, role, status)
  values (new.id,
          nullif(trim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), ''),
          nullif(trim(coalesce(new.raw_user_meta_data ->> 'phone', '')), ''),
          new.email,
          'operator',
          'pending')
  on conflict (auth_user_id) do nothing;

  return new;

-- A trigger on auth.users runs INSIDE Supabase's signup transaction. If it
-- raises, the whole signup is rolled back and the person is told their
-- account could not be created - so a fault here would break the one thing
-- this migration exists to protect. Swallow it, log it, and let the login
-- through: an account with no staff row can be repaired by hand, but an
-- account that was never created cannot be repaired at all.
exception when others then
  raise warning 'handle_new_auth_user: no staff row for % (%)', new.email, sqlerrm;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_auth_user();

-- ---------------------------------------------------------------
-- register_staff, now that it is no longer load-bearing
-- ---------------------------------------------------------------
-- The trigger gets there first, so by the time the browser calls this the row
-- usually exists. The old body answered that with 'account already
-- registered', which was true and unhelpful - it would have shown a first-time
-- signup a message about an account they had just made.
--
-- What it is actually for now is filling in what the trigger could not. The
-- trigger reads the name from metadata; if the app is an older build that
-- does not send metadata, the name arrives here instead. Either way the
-- outcome is the same, so report the same thing.
--
-- coalesce(nullif(...), full_name) means a blank submission never erases a
-- name that is already there.
create or replace function register_staff(p_full_name text, p_phone text default null)
returns json
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return json_build_object('success', false, 'message', 'not authenticated');
  end if;

  update staff
     set full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
         phone     = coalesce(nullif(trim(p_phone), ''), phone)
   where auth_user_id = v_uid;

  if found then
    return json_build_object('success', true, 'message', 'awaiting admin approval');
  end if;

  -- No row yet: an older database without the trigger, or a login created
  -- before this migration ran. Same outcome, reached the long way.
  insert into staff (auth_user_id, full_name, phone, email, role, status)
  values (v_uid,
          nullif(trim(p_full_name), ''),
          nullif(trim(p_phone), ''),
          (select email from auth.users where id = v_uid),
          'operator', 'pending')
  on conflict (auth_user_id) do nothing;

  return json_build_object('success', true, 'message', 'awaiting admin approval');
end $$;

grant execute on function register_staff(text, text) to anon, authenticated;

commit;

-- PostgREST serves from a cached picture of the schema. register_staff kept
-- its signature, so this is belt and braces rather than strictly required -
-- but 0009 taught us what a stale cache looks like from the outside, and it
-- costs nothing.
notify pgrst, 'reload schema';

-- ===============================================================
-- REPAIR: logins that were created before this ran
-- ===============================================================
-- Anyone who signed up while confirmation was on has a login and no staff
-- row. The trigger only fires on new inserts, so it will not go back for
-- them. This does, once:
--
--   insert into public.staff (auth_user_id, full_name, phone, email, role, status)
--   select u.id,
--          nullif(trim(coalesce(u.raw_user_meta_data ->> 'full_name', '')), ''),
--          nullif(trim(coalesce(u.raw_user_meta_data ->> 'phone', '')), ''),
--          u.email, 'operator', 'pending'
--     from auth.users u
--    where not exists (select 1 from public.staff s where s.auth_user_id = u.id)
--   returning full_name, email, role, status;
--
-- full_name will be null for anyone who signed up through a build of the app
-- that did not send metadata. They show in the staff list with a blank name,
-- which is visible and fixable, rather than absent and invisible:
--
--   update public.staff set full_name = 'Their Name' where email = '...';
--
-- ===============================================================
-- VERIFY
-- ===============================================================
-- 1. The trigger is attached:
--
--      select tgname, tgenabled from pg_trigger
--       where tgrelid = 'auth.users'::regclass and not tgisinternal;
--
--    Expect on_auth_user_created, and tgenabled = 'O'.
--
-- 2. Every login has a staff row - this is the invariant the whole migration
--    exists to hold, and it is one query:
--
--      select count(*) as logins_without_staff
--        from auth.users u
--       where not exists (select 1 from public.staff s where s.auth_user_id = u.id);
--
--    Expect 0, now and after every future signup.
--
-- 3. A real signup still works: have someone create an account and check they
--    appear in the staff list as pending, with their name filled in.
