-- The fixture's auth.users is a minimal stand-in: id and email, which is all
-- 0001-0008 ever read. 0010's trigger also reads raw_user_meta_data, the
-- column Supabase writes signUp({ options: { data } }) into. Adding it here
-- keeps the fixture honest for the older migrations while letting 0010 be
-- tested against the shape it actually runs on.
alter table auth.users add column if not exists raw_user_meta_data jsonb;

-- Supabase ships anon and authenticated; a bare Postgres does not, and the
-- grant at the end of 0010 fails without them.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;
