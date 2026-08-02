-- 0020 — a shift from before the pumps existed stops blocking the till
--
-- Found in the live data, not by reading:
--
--   full_name,     branch, pump,   opened_at,             closed_at
--   Ehab Abdosh,   Adama,  null,   2026-07-31 22:10:58,   null
--
-- That shift has been open for two days and can never close. It was opened
-- before 0016, so it has no nozzle, and every route out of it now goes
-- through one:
--
--   * open_shift only abandons a stale shift on THE NOZZLE BEING OPENED.
--     0015 abandoned any of your own from a previous day; 0016 narrowed that
--     to `where nozzle_id = p_nozzle_id`, which a null nozzle never matches.
--     So it is never swept.
--   * my_open_shifts still returns it, with a null label, so the dashboard
--     shows an open shift with no pump name and the sale box offers it as an
--     option with no value behind it.
--   * record_sale then refuses - correctly - because there is no shift on
--     the nozzle it was handed. The cashier reads "open a shift first" while
--     looking at a screen that says one is open.
--
-- That is the "staff cannot save a sale" report: not a failure to write, but
-- a dead row standing between them and the till.
--
-- Three parts: clear the dead rows, stop them reaching the sale box, and
-- restore the overnight sweep 0016 narrowed - without breaking the thing
-- 0016 was for. One person on two pumps at once is normal and must keep
-- working, so the sweep only touches shifts from a PREVIOUS local day.

begin;

-- ---------------------------------------------------------------
-- 1. the dead rows
-- ---------------------------------------------------------------
-- No nozzle means no meter, which means no variance was ever obtainable
-- from this row. Abandoned says that. Inventing a closing meter for it
-- would put a made-up number into the one column that exists to find
-- missing fuel.
update shifts
   set abandoned = true
 where closed_at is null
   and not abandoned
   and nozzle_id is null;

-- ---------------------------------------------------------------
-- 2. what the cashier's own page offers
-- ---------------------------------------------------------------
-- The sale box is built from this list, so a row with no nozzle here becomes
-- an option that cannot sell. Belt and braces: after (1) there are none, and
-- after (3) no more can be made, but this is the query the till trusts.
create or replace function my_open_shifts()
returns table (id uuid, nozzle_id uuid, nozzle_label text, fuel_type text,
               opened_at timestamptz, opening_meter numeric, sold_liters numeric)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.nozzle_id, n.label, n.fuel_type, sh.opened_at, sh.opening_meter,
         coalesce((select sum(s.liters) from sales s
                    where s.nozzle_id = sh.nozzle_id
                      and not coalesce(s.voided, false)
                      and s.created_at >= sh.opened_at), 0)
    from shifts sh
    join nozzles n on n.id = sh.nozzle_id
   where sh.staff_id = (select id from current_staff())
     and sh.closed_at is null and not sh.abandoned
   order by sh.opened_at;
$$;

-- ---------------------------------------------------------------
-- 3. the overnight sweep, back to covering the person
-- ---------------------------------------------------------------
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

  -- Anything of theirs still open from a previous day, on any pump or none.
  -- Yesterday's shift cannot be closed against today's meter, so there is
  -- nothing to salvage; leaving it open is what wedged the till.
  --
  -- Today's are left alone. Two pumps at once is the working day this whole
  -- feature was built for, and sweeping those would break it.
  update shifts set abandoned = true
   where staff_id = v_staff.id
     and closed_at is null and not abandoned
     and (opened_at at time zone app_timezone())::date < v_today;

  -- Somebody else already on this pump.
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
    -- Left open overnight by someone else: same reasoning, their row.
    update shifts set abandoned = true where id = v_open.id;
  end if;

  insert into shifts (station_id, staff_id, nozzle_id, opening_meter, opened_at)
  values (v_staff.station_id, v_staff.id, p_nozzle_id, p_opening_meter, now());

  return json_build_object('success', true, 'message', 'shift opened on ' || v_noz.label);
end; $$;

grant execute on function my_open_shifts()          to authenticated;
grant execute on function open_shift(uuid, numeric) to authenticated;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select count(*) as still_stuck from shifts
--    where closed_at is null and not abandoned and nozzle_id is null;
--
-- Expect 0.
--
--   select staff_name, nozzle_label, opened_at, closed_at, abandoned
--     from list_shifts(null, 7, 200) order by opened_at desc;
--
-- Ehab Abdosh's Adama row now reads abandoned. It stays visible - the
-- manager should be able to see that a day went unrecorded, rather than
-- have it quietly deleted.
