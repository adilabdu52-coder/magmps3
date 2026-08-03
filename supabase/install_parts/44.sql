-- MAGPMS install 44 of 44 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Saying what is actually in a tank. Every other tank write in this database
-- is a + or a -: a sale takes fuel out, a delivery puts it in. This is the
-- one figure that is a measurement rather than a calculation.
--
-- Without it, a manager whose tank reads wrong has to record a delivery that
-- never arrived - which fixes the number and puts a lie in the history.
set search_path = public, extensions;

create or replace function admin_set_tank_level(
  p_tank_id int, p_liters numeric, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_admin staff := current_staff();
  t tanks;
  v_station text;
begin
  if not is_admin() then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;

  select * into t from tanks where id = p_tank_id;
  if t.id is null then return json_build_object('success', false, 'message', 'no such tank'); end if;

  if p_liters is null or p_liters < 0 then
    return json_build_object('success', false, 'message', 'enter the litres in the tank');
  end if;
  -- A stick cannot read more than the tank holds, so this is a typo. Letting
  -- it through would make every stock percentage on the dashboard nonsense.
  if t.capacity_liters is not null and p_liters > t.capacity_liters then
    return json_build_object('success', false,
      'message', format('that is more than the tank holds (%s L) - check the figure',
                        round(t.capacity_liters)));
  end if;

  update tanks set current_liters = p_liters where id = p_tank_id;

  -- Written down, because a stock figure that changed by hand and left no
  -- trace is indistinguishable from one that drifted.
  select name into v_station from stations where id = t.station_id;
  insert into branch_notes (station_id, body, pinned, created_by)
  values (t.station_id,
          format('Tank level set by hand: %s %s from %s L to %s L.%s',
                 coalesce(v_station, ''), coalesce(t.tank_name, ''),
                 round(coalesce(t.current_liters, 0)), round(p_liters),
                 case when coalesce(trim(p_note), '') = '' then ''
                      else ' ' || trim(p_note) end),
          false, v_admin.id);

  return json_build_object('success', true,
    'message', format('%s set to %s L', coalesce(t.tank_name, 'tank'), round(p_liters)),
    'was', round(coalesce(t.current_liters, 0)), 'now', round(p_liters));
end; $$;

grant execute on function admin_set_tank_level(int, numeric, text) to authenticated;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select t.id, st.name, t.tank_name, t.fuel_type,
--          t.current_liters, t.capacity_liters
--     from tanks t join stations st on st.id = t.station_id
--    order by st.name, t.tank_name;
--
--   select admin_set_tank_level(1, 12400, 'dipped after the reset');
