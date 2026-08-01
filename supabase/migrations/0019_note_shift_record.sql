-- 0019 — a note can record a shift, not just describe one
--
-- 0018 gave the manager somewhere to write. What they actually want to write
-- down is a shift: which branch, who worked it, which pump, how much of each
-- fuel went out, and the meter at the start and the end.
--
-- Typed as a sentence that is a paragraph nobody can add up. As fields it is
-- a record - one you can total, compare against what the tills say, and read
-- back in a year.
--
-- This does not replace the shifts table. A shift there is what the system
-- observed: opened by a cashier, closed against a meter, with sales attached.
-- A note here is what the MANAGER observed, written by hand, and the two
-- being separate is the point - a hand-written record that silently merged
-- into the system's own would be worth nothing as a check on it.
--
-- Every field is optional. A note that is only a sentence still works, which
-- is what most of them will be.

begin;

alter table branch_notes add column if not exists staff_id     uuid references staff(id);
alter table branch_notes add column if not exists nozzle_id    uuid references nozzles(id);
alter table branch_notes add column if not exists start_meter  numeric;
alter table branch_notes add column if not exists end_meter    numeric;

-- Litres per fuel, keyed by the fuel's own name: {"Diesel": 120, "Benzil": 40}
--
-- Not two columns called diesel and petrol. This business sells Benzil and
-- Diesel today and the fuels come from the database everywhere else in the
-- app - there is a CI check that fails the build if a fuel name is written
-- into the markup. A branch that starts selling a third fuel gets a third
-- box, with no migration and no code change.
alter table branch_notes add column if not exists fuel_liters jsonb;

-- ---------------------------------------------------------------
-- writing one
-- ---------------------------------------------------------------
drop function if exists admin_add_note(text, uuid, boolean);

create or replace function admin_add_note(
  p_body text,
  p_station_id uuid default null,
  p_pinned boolean default false,
  p_staff_id uuid default null,
  p_nozzle_id uuid default null,
  p_start_meter numeric default null,
  p_end_meter numeric default null,
  p_fuel_liters jsonb default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_admin staff := current_staff(); v_id uuid;
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;

  -- A note with figures on it does not also need a sentence. One with
  -- neither is nothing at all.
  if coalesce(trim(p_body), '') = ''
     and p_staff_id is null and p_nozzle_id is null
     and p_start_meter is null and p_end_meter is null
     and p_fuel_liters is null then
    return json_build_object('success', false, 'message', 'write something first');
  end if;

  if p_station_id is not null
     and not exists (select 1 from stations where id = p_station_id) then
    return json_build_object('success', false, 'message', 'no such branch');
  end if;
  if p_staff_id is not null
     and not exists (select 1 from staff where id = p_staff_id) then
    return json_build_object('success', false, 'message', 'no such staff member');
  end if;
  if p_nozzle_id is not null
     and not exists (select 1 from nozzles where id = p_nozzle_id) then
    return json_build_object('success', false, 'message', 'no such pump');
  end if;

  -- A pump meter only counts up. This is the manager's own record, so it is
  -- worth catching a slip here for the same reason it is worth catching in
  -- close_shift: a reversed pair reads as fuel appearing from nowhere.
  if p_start_meter is not null and p_end_meter is not null
     and p_end_meter < p_start_meter then
    return json_build_object('success', false,
      'message', 'the end reading is below the start - check the figures');
  end if;

  insert into branch_notes (station_id, body, pinned, created_by,
                            staff_id, nozzle_id, start_meter, end_meter, fuel_liters)
  values (p_station_id, coalesce(trim(p_body), ''), coalesce(p_pinned, false), v_admin.id,
          p_staff_id, p_nozzle_id, p_start_meter, p_end_meter, p_fuel_liters)
  returning id into v_id;

  return json_build_object('success', true, 'message', 'note saved', 'id', v_id);
end; $$;

-- ---------------------------------------------------------------
-- reading them back
-- ---------------------------------------------------------------
drop function if exists admin_list_notes(uuid, int);

create or replace function admin_list_notes(
  p_station_id uuid default null, p_limit int default 100)
returns table (id uuid, station_id uuid, station_name text, body text,
               pinned boolean, author text, created_at timestamptz,
               updated_at timestamptz,
               staff_name text, nozzle_label text,
               start_meter numeric, end_meter numeric, metered_liters numeric,
               fuel_liters jsonb, noted_liters numeric)
language sql stable security definer set search_path = public
as $$
  select n.id, n.station_id, coalesce(st.name, 'All branches'), n.body,
         n.pinned, stf.full_name, n.created_at, n.updated_at,
         who.full_name, noz.label,
         n.start_meter, n.end_meter,
         case when n.start_meter is null or n.end_meter is null then null
              else n.end_meter - n.start_meter end,
         n.fuel_liters,
         -- The fuels added up, so the manager can see at a glance whether
         -- what they wrote per fuel agrees with what the meter moved.
         (select sum((value)::text::numeric)
            from jsonb_each(coalesce(n.fuel_liters, '{}'::jsonb)))
    from branch_notes n
    left join stations st on st.id = n.station_id
    left join staff stf   on stf.id = n.created_by
    left join staff who   on who.id = n.staff_id
    left join nozzles noz on noz.id = n.nozzle_id
   where is_admin()
     and (p_station_id is null or n.station_id = p_station_id or n.station_id is null)
   order by n.pinned desc, n.created_at desc
   limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

grant execute on function admin_add_note(text, uuid, boolean, uuid, uuid, numeric, numeric, jsonb)
  to authenticated;
grant execute on function admin_list_notes(uuid, int) to authenticated;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select admin_add_note(
--     'Morning shift',
--     (select id from stations where name = 'Adama'),
--     false,
--     (select id from staff where full_name = 'Ehab Abdosh'),
--     (select id from nozzles where label = 'Pump 1'
--       and station_id = (select id from stations where name = 'Adama')),
--     1000, 1180,
--     '{"Diesel": 120, "Benzil": 60}'::jsonb);
--
--   select staff_name, nozzle_label, start_meter, end_meter,
--          metered_liters, noted_liters
--     from admin_list_notes(null) where staff_name is not null;
--
-- metered_liters is 180 and noted_liters is 180. When those two disagree,
-- the manager's own arithmetic is worth a second look before anybody else's.
