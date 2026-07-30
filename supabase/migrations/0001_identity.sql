-- 0001 — one identity, from Supabase Auth
--
-- Written to adapt to the live schema rather than assume it. Every statement
-- is guarded, so this is safe to run twice and will not fail on a column that
-- already exists.
--
-- WHAT CHANGES
--   The database has two credential tables, `admins` and `staff`, each with
--   username + password_hash. The app cannot express "this caller is an
--   admin" against that: PostgREST authenticates every request as the same
--   anon role, so no function can tell who is calling. Identity moves to
--   Supabase Auth, and `staff` becomes the single table, with admins as rows
--   where role = 'admin'.
--
--   `admins` is NOT dropped. It is left in place, unused, so nothing is lost
--   if this needs revisiting. Drop it yourself once you are satisfied.

begin;

-- ---------------------------------------------------------------
-- 1. staff gains the columns the app needs, if it lacks them
-- ---------------------------------------------------------------
alter table staff add column if not exists auth_user_id uuid unique references auth.users(id) on delete set null;
alter table staff add column if not exists email  text;
alter table staff add column if not exists phone  text;
alter table staff add column if not exists role   text;
alter table staff add column if not exists status text;

-- Existing rows may predate these columns.
update staff set role   = 'operator' where role   is null;
update staff set status = 'approved' where status is null;

alter table staff alter column role   set default 'operator';
alter table staff alter column status set default 'pending';

create index if not exists staff_auth_user_id_idx on staff (auth_user_id);

-- ---------------------------------------------------------------
-- 2. fold admins into staff
-- ---------------------------------------------------------------
-- Matched on username, which both tables carry. An admin whose username is
-- already a staff row is promoted rather than duplicated.
do $$
begin
  if to_regclass('public.admins') is null then
    raise notice 'no admins table - nothing to merge';
    return;
  end if;

  update staff s
     set role = 'admin', status = 'approved'
    from admins a
   where a.username = s.username;

  /* password_hash is carried across only if it is still there. 0009 drops it,
     and a static reference to it would make this file fail the second time it
     is run on a database that has been all the way through. A migration you
     cannot re-run is one you have to remember the state of. */
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'staff'
                and column_name = 'password_hash') then
    execute $q$
      insert into staff (id, full_name, username, password_hash, role, status, created_at)
      select a.id, a.full_name, a.username, a.password_hash, 'admin', 'approved', a.created_at
        from admins a
       where not exists (select 1 from staff s where s.username = a.username)
    $q$;
  else
    execute $q$
      insert into staff (id, full_name, username, role, status, created_at)
      select a.id, a.full_name, a.username, 'admin', 'approved', a.created_at
        from admins a
       where not exists (select 1 from staff s where s.username = a.username)
    $q$;
  end if;

  raise notice 'admins merged into staff';
end $$;

-- ---------------------------------------------------------------
-- 3. helper functions - the only place identity is decided
-- ---------------------------------------------------------------
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

-- current_station() is NOT created here. It reads staff.station_id, and that
-- column does not exist until 0002 adds it - Postgres validates a SQL function
-- body when the function is created, so defining it now fails outright on a
-- database that has not been through 0002 yet. It is created there instead,
-- once the column it depends on is real.

commit;

-- ===============================================================
-- AFTER RUNNING THIS, BEFORE 0002
-- ===============================================================
-- Every person needs an auth.users row, and staff.auth_user_id must point at
-- it. Existing password_hash values cannot be carried across - Supabase Auth
-- hashes differently - so each person sets a password once.
--
-- Run this in a terminal, NOT in the SQL editor. It needs the service_role
-- key, which must never appear in client code or be pasted into a chat.
--
--   // create-auth-users.mjs
--   import { createClient } from "@supabase/supabase-js";
--   const db = createClient(
--     "https://lnqwooqpnlxifxeukozd.supabase.co",
--     process.env.SERVICE_ROLE_KEY               // export it, do not inline it
--   );
--
--   const { data: staff } = await db.from("staff").select("id, username, email");
--   for (const s of staff) {
--     const email = s.email ?? `${s.username}@magpms.local`;   // placeholder domain
--     const { data, error } = await db.auth.admin.createUser({
--       email,
--       password: "ChangeMe#2026",                             // reset on first login
--       email_confirm: true
--     });
--     if (error) { console.log(s.username, error.message); continue; }
--     await db.from("staff").update({ auth_user_id: data.user.id, email }).eq("id", s.id);
--     console.log("linked", s.username, "->", email);
--   }
--
-- Then verify none were missed:
--   select username, role, auth_user_id is null as unlinked from staff order by unlinked desc;
--
-- A staff row with auth_user_id null cannot sign in - current_staff() returns
-- nothing for them.
