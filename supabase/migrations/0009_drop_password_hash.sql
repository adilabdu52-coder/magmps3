-- 0009 — remove the old password hashes
--
-- staff.password_hash is left over from the login system this app replaced.
-- Nothing reads it: not one function in 0004 or 0007, not one page. 0001
-- copied it across when folding admins into staff, and it has been dead weight
-- since identity moved to Supabase Auth.
--
-- Dead, but not harmless. These are real password hashes produced by a system
-- whose hashing method was never established - it could be bcrypt, or md5, or
-- nothing at all. People reuse passwords between systems, so if this table ever
-- leaked, the damage would not stop at this app. A column nobody reads is pure
-- liability: it can only ever cost something.
--
-- Current passwords are unaffected. Supabase Auth keeps those as bcrypt in
-- auth.users.encrypted_password, in a different schema this app has never been
-- granted access to.

begin;

-- ---------------------------------------------------------------
-- say what is about to happen, and to how many rows
-- ---------------------------------------------------------------
do $$
declare
  v_total int;
  v_with  int;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'staff'
                    and column_name = 'password_hash') then
    raise notice 'staff.password_hash is already gone - nothing to do';
    return;
  end if;

  select count(*) into v_total from staff;
  execute 'select count(*) from staff where password_hash is not null' into v_with;

  raise notice 'staff rows: %, of which % still carry an old password hash', v_total, v_with;
  if v_with = 0 then
    raise notice 'none left - this drop is tidying, not remediation';
  end if;
end $$;

-- ---------------------------------------------------------------
-- refuse rather than cascade
-- ---------------------------------------------------------------
-- No `cascade`. If a view, index or constraint turns out to depend on this
-- column, Postgres aborts and names it, instead of quietly removing whatever
-- was built on top. An unexpected dependency is information, not an obstacle.
alter table staff drop column if exists password_hash;

commit;

-- ---------------------------------------------------------------
-- a note on staff.username, deliberately not dropped
-- ---------------------------------------------------------------
-- username is equally unused - the app matches on auth_user_id and shows
-- full_name - and every remaining row has it null, because rows created
-- through register_staff never set it. It could go the same way.
--
-- It is left alone because it is not credential material. The case for
-- dropping password_hash is that keeping it carries risk; the case for
-- dropping username is only tidiness, and that is a weaker reason to remove
-- a column from a live database. Drop it if you want to:
--
--   alter table staff drop column if exists username;

-- ===============================================================
-- VERIFY
-- ===============================================================
-- 1. The column is gone:
--
--      select column_name from information_schema.columns
--       where table_schema = 'public' and table_name = 'staff'
--       order by ordinal_position;
--
--    Expect no password_hash. auth_user_id, email, phone, role, status and
--    station_id all remain - those are what identity actually runs on.
--
-- 2. Identity still resolves. current_staff() returns the staff composite
--    type, so the type's shape changes with the table. Nothing needs
--    recreating: this was run on Postgres 16 against a copy of this schema,
--    including a plpgsql function holding `declare v_staff staff` that was
--    compiled BEFORE the drop - the shape plpgsql resolves at runtime, so
--    record_sale, open_shift and check_in all keep working untouched.
--    Worth confirming here anyway, since it costs one query:
--
--      select id, full_name, role, status from current_staff();
--      select is_admin();
--
--    Run signed in as yourself. Expect your row, and true.
--
-- 3. The app still works: sign out, sign back in, open the dashboard. If
--    identity had broken, sign-in would fail at me() rather than silently.
