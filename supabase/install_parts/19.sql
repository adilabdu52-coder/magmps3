-- MAGPMS install 19 of 19 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- This one is new. Parts 1-18 install the system; this makes signing up work
-- whether or not the project asks for e-mail confirmation, by having the
-- database build the staff row instead of the browser.
set search_path = public, extensions;
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



-- PostgREST serves from a cached picture of the schema. register_staff kept
-- its signature, so this is belt and braces rather than strictly required -
-- but 0009 taught us what a stale cache looks like from the outside, and it
-- costs nothing.
notify pgrst, 'reload schema';


