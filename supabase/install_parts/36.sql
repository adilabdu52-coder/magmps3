-- MAGPMS install 36 of 39 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Notes, part 3: a note can record a shift - who, which pump, the meter at
-- each end, and litres per fuel.
set search_path = public, extensions;
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


