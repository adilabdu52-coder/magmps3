-- 0018 — a private notebook, per branch
--
-- Everything this app records is a transaction: a sale, a delivery, a shift.
-- None of it holds the things a manager actually needs to remember about a
-- branch. Which pumps are diesel and which are petrol. When the shift starts
-- and ends there. That tank three's gauge reads low and always has.
--
-- Those live in somebody's head or on a phone note, and neither survives the
-- person being away. This puts them next to the branch they belong to.
--
-- Admin only, and firmly so. A note may say "check Abebe's readings on pump
-- 4" - a reasonable thing for a manager to write and a corrosive thing for
-- Abebe to find. The whole value of a private note is that it is private, so
-- there is no route to it for anybody else: RLS is on, no policies exist, and
-- every function checks is_admin() before it reads a single row.

begin;

create table if not exists branch_notes (
  id         uuid primary key default gen_random_uuid(),
  -- null means the note is about the whole business rather than one branch,
  -- which is why this is nullable and why the reads treat null specially.
  station_id uuid references stations(id),
  body       text not null,
  pinned     boolean not null default false,
  created_by uuid references staff(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz);

create index if not exists branch_notes_station_idx
  on branch_notes (station_id, pinned desc, created_at desc);

alter table branch_notes enable row level security;
revoke all on branch_notes from anon, authenticated;

-- ---------------------------------------------------------------
-- writing one
-- ---------------------------------------------------------------
create or replace function admin_add_note(
  p_body text, p_station_id uuid default null, p_pinned boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare v_admin staff := current_staff(); v_id uuid;
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if coalesce(trim(p_body), '') = '' then
    return json_build_object('success', false, 'message', 'write something first');
  end if;
  if p_station_id is not null
     and not exists (select 1 from stations where id = p_station_id) then
    return json_build_object('success', false, 'message', 'no such branch');
  end if;

  insert into branch_notes (station_id, body, pinned, created_by)
  values (p_station_id, trim(p_body), coalesce(p_pinned, false), v_admin.id)
  returning id into v_id;

  return json_build_object('success', true, 'message', 'note saved', 'id', v_id);
end; $$;

-- ---------------------------------------------------------------
-- reading them
-- ---------------------------------------------------------------
-- A branch's notes always include the ones written about the whole business,
-- because "shift starts at 6" is as true at Hirna as anywhere and should not
-- have to be written five times.
create or replace function admin_list_notes(
  p_station_id uuid default null, p_limit int default 100)
returns table (id uuid, station_id uuid, station_name text, body text,
               pinned boolean, author text, created_at timestamptz,
               updated_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select n.id, n.station_id, coalesce(st.name, 'All branches'), n.body,
         n.pinned, stf.full_name, n.created_at, n.updated_at
    from branch_notes n
    left join stations st on st.id = n.station_id
    left join staff stf on stf.id = n.created_by
   where is_admin()
     and (p_station_id is null or n.station_id = p_station_id or n.station_id is null)
   order by n.pinned desc, n.created_at desc
   limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

-- ---------------------------------------------------------------
-- changing and removing one
-- ---------------------------------------------------------------
-- Pinning is the "mark" - a note that matters stays at the top instead of
-- sinking under everything written since.
create or replace function admin_set_note(
  p_note_id uuid, p_body text default null, p_pinned boolean default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if p_body is not null and trim(p_body) = '' then
    return json_build_object('success', false, 'message', 'a note cannot be emptied - delete it instead');
  end if;

  update branch_notes
     set body       = coalesce(nullif(trim(p_body), ''), body),
         pinned     = coalesce(p_pinned, pinned),
         updated_at = now()
   where id = p_note_id;

  if not found then return json_build_object('success', false, 'message', 'no such note'); end if;
  return json_build_object('success', true, 'message', 'note updated');
end; $$;

create or replace function admin_delete_note(p_note_id uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  delete from branch_notes where id = p_note_id;
  if not found then return json_build_object('success', false, 'message', 'no such note'); end if;
  return json_build_object('success', true, 'message', 'note deleted');
end; $$;

grant execute on function admin_add_note(text, uuid, boolean)    to authenticated;
grant execute on function admin_list_notes(uuid, int)            to authenticated;
grant execute on function admin_set_note(uuid, text, boolean)    to authenticated;
grant execute on function admin_delete_note(uuid)                to authenticated;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- A NOTE ON PRIVACY, SINCE THAT IS THE POINT
-- ===============================================================
-- These are private from staff, not from the business. An admin can read
-- every note, and the backup in 0014 does not include this table - add it
-- there if you would rather they were kept.
--
-- What they are not is secret from anybody with the database password. Do not
-- write anything here you would not want in a Supabase dashboard: no
-- passwords, no bank details.
--
-- ===============================================================
-- VERIFY
-- ===============================================================
--   select admin_add_note('Pumps 1 and 2 are Benzil, the rest Diesel',
--            (select id from stations where name = 'Adama'), true);
--   select station_name, body, pinned from admin_list_notes(null);
