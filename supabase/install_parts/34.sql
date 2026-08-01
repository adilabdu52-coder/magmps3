-- MAGPMS install 34 of 37 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Private notes, part 1: the table, writing one, and reading them back.
-- Admin only - staff have no route to these at all.
set search_path = public, extensions;
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


