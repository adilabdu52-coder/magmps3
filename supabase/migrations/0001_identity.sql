-- 0001 — real identity
--
-- ⚠ VERIFY BEFORE RUNNING. These migrations are written against a schema
--   inferred from the old frontend's reads (staff.full_name, sales.total_etb,
--   tanks.current_liters, …). Dump the real one first and reconcile names:
--
--     SELECT table_name, column_name, data_type
--     FROM information_schema.columns
--     WHERE table_schema = 'public'
--     ORDER BY table_name, ordinal_position;
--
-- WHY THIS COMES FIRST
--   The old app passed the caller's own id as a parameter (p_admin_id from
--   localStorage) while every request used the same anon key. auth.uid() was
--   null, so no function could check who was calling - any client could claim
--   to be any admin. Station scoping on top of that would just add a second
--   forgeable parameter, so identity has to be real before anything else.

begin;

-- Link staff rows to Supabase Auth users.
alter table staff add column if not exists auth_user_id uuid unique references auth.users(id) on delete set null;
alter table staff add column if not exists email text;

create index if not exists staff_auth_user_id_idx on staff (auth_user_id);

-- The staff row for the caller, or nothing. SECURITY DEFINER so it can read
-- staff while RLS blocks direct access.
create or replace function current_staff()
returns staff
language sql stable security definer set search_path = public
as $$
  select * from staff where auth_user_id = auth.uid() limit 1;
$$;

create or replace function is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select role = 'admin' and status = 'approved' from current_staff()), false);
$$;

-- The caller's branch. Null for the central admin, who is not tied to one.
create or replace function current_station()
returns uuid
language sql stable security definer set search_path = public
as $$
  select station_id from current_staff();
$$;

-- What the pages call on load to learn who they are serving.
create or replace function me()
returns table (
  id uuid, full_name text, email text, phone text, role text, status text,
  station_id uuid, station_name text
)
language sql stable security definer set search_path = public
as $$
  select s.id, s.full_name, s.email, s.phone, s.role, s.status,
         s.station_id, st.name
  from current_staff() s
  left join stations st on st.id = s.station_id;
$$;

-- Signup: the auth user already exists; this creates the staff row against it.
-- Status is pending and station is null - an admin sets both.
create or replace function register_staff(p_full_name text, p_phone text default null)
returns json
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return json_build_object('success', false, 'message', 'not authenticated');
  end if;
  if exists (select 1 from staff where auth_user_id = v_uid) then
    return json_build_object('success', false, 'message', 'account already registered');
  end if;

  insert into staff (auth_user_id, full_name, phone, email, role, status)
  values (v_uid, p_full_name, p_phone,
          (select email from auth.users where id = v_uid), 'operator', 'pending');

  return json_build_object('success', true, 'message', 'awaiting admin approval');
end;
$$;

commit;

-- AFTER RUNNING: create an auth user for each existing staff row and set
-- auth_user_id, e.g. via supabase.auth.admin.createUser() in a one-off script.
-- Until every row is linked those staff cannot sign in.
--
-- Also check how passwords were stored before:
--   SELECT prosrc FROM pg_proc WHERE proname IN ('login_staff','register_staff');
-- If the body compares p_password directly, they were plaintext. Moving to
-- Supabase Auth retires those functions - drop them once nothing calls them.
