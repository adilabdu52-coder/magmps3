-- MAGPMS install 2 of 19 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

update staff set status = 'approved' where status is null;

alter table staff alter column role   set default 'operator';

alter table staff alter column status set default 'pending';

create index if not exists staff_auth_user_id_idx on staff (auth_user_id);

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

create table if not exists stations (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  town       text,
  created_at timestamptz not null default now()
);

insert into stations (name, town) values
  ('Adama',     'Adama, East Shewa'),
  ('Dire Dawa', 'Dire Dawa'),
  ('Hirna',     'Hirna, West Hararghe'),
  ('Woleciti',  'Woleciti, East Shewa'),
  ('Heromaya',  'Heromaya, East Hararghe')
on conflict (name) do nothing;
