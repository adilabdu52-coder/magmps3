-- MAGPMS install 39 of 39 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Stale shifts, part 2: opening a pump sweeps anything of yours still open
-- from a PREVIOUS day, on any pump or none - so no more can get stuck.
set search_path = public, extensions;

create or replace function open_shift(p_nozzle_id uuid, p_opening_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  v_noz   nozzles;
  v_open  shifts;
  v_today date;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if v_staff.station_id is null then
    return json_build_object('success', false,
      'message', 'no branch assigned - ask the manager before opening a shift');
  end if;
  if p_opening_meter is null or p_opening_meter < 0 then
    return json_build_object('success', false, 'message', 'enter the opening meter reading');
  end if;

  select * into v_noz from nozzles where id = p_nozzle_id;
  if v_noz.id is null then
    return json_build_object('success', false, 'message', 'choose a nozzle');
  end if;
  if v_noz.station_id <> v_staff.station_id then
    return json_build_object('success', false, 'message', 'that nozzle is at another branch');
  end if;
  if not v_noz.active then
    return json_build_object('success', false, 'message', 'that nozzle is out of service');
  end if;

  v_today := (now() at time zone app_timezone())::date;

  -- Anything of theirs still open from a previous day. Yesterday's shift
  -- cannot be closed against today's meter, so there is nothing to salvage;
  -- leaving it open is what wedged the till.
  --
  -- Today's are left alone. Two pumps at once is the ordinary working day,
  -- and sweeping those would break it.
  update shifts set abandoned = true
   where staff_id = v_staff.id
     and closed_at is null and not abandoned
     and (opened_at at time zone app_timezone())::date < v_today;

  select * into v_open from shifts
   where nozzle_id = p_nozzle_id and closed_at is null and not abandoned
   order by opened_at desc limit 1;

  if v_open.id is not null then
    if (v_open.opened_at at time zone app_timezone())::date = v_today then
      return json_build_object('success', false,
        'message', case when v_open.staff_id = v_staff.id
                        then 'you already have this nozzle open'
                        else 'somebody else has this nozzle open' end);
    end if;
    update shifts set abandoned = true where id = v_open.id;
  end if;

  insert into shifts (station_id, staff_id, nozzle_id, opening_meter, opened_at)
  values (v_staff.station_id, v_staff.id, p_nozzle_id, p_opening_meter, now());

  return json_build_object('success', true, 'message', 'shift opened on ' || v_noz.label);
end; $$;

grant execute on function open_shift(uuid, numeric) to authenticated;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select staff_name, nozzle_label, opened_at, closed_at, abandoned
--     from list_shifts(null, 7, 200) order by opened_at desc;
--
-- The Adama row with no pump now reads abandoned. It stays visible - a day
-- that went unrecorded is worth seeing, not quietly deleting.
