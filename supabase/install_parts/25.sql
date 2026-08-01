-- MAGPMS install 25 of 31 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Shifts and attendance, part 1: a forgotten check-out must not lock
-- somebody out the next day.
set search_path = public, extensions;
alter table attendance add column if not exists abandoned boolean not null default false;
alter table shifts     add column if not exists abandoned boolean not null default false;

create index if not exists attendance_open_idx
  on attendance (staff_id) where check_out is null and not abandoned;
create index if not exists shifts_open_idx
  on shifts (staff_id) where closed_at is null and not abandoned;

-- ---------------------------------------------------------------
-- checking in
-- ---------------------------------------------------------------
create or replace function check_in()
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  v_open  attendance;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;

  -- Refuse rather than write a row the manager will never see. Fault (2).
  if v_staff.station_id is null then
    return json_build_object('success', false,
      'message', 'no branch assigned - ask the manager before checking in');
  end if;

  select * into v_open from attendance
   where staff_id = v_staff.id and check_out is null and not abandoned
   order by check_in desc limit 1;

  if v_open.id is not null then
    if (v_open.check_in at time zone app_timezone())::date
       = (now() at time zone app_timezone())::date then
      return json_build_object('success', false, 'message', 'already checked in today');
    end if;

    -- From a previous day: they went home and forgot. Mark it, do not invent
    -- a time for it, and let today proceed.
    update attendance set abandoned = true where id = v_open.id;
  end if;

  insert into attendance (station_id, staff_id, check_in)
  values (v_staff.station_id, v_staff.id, now());

  return json_build_object('success', true, 'message', 'checked in');
end; $$;

create or replace function check_out()
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); v_id uuid;
begin
  if v_staff.id is null then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;

  select id into v_id from attendance
   where staff_id = v_staff.id and check_out is null and not abandoned
   order by check_in desc limit 1;
  if v_id is null then return json_build_object('success', false, 'message', 'not checked in'); end if;

  update attendance set check_out = now() where id = v_id;
  return json_build_object('success', true, 'message', 'checked out');
end; $$;

create or replace function my_attendance_status()
returns table (id uuid, check_in timestamptz, check_out timestamptz)
language sql stable security definer set search_path = public
as $$
  select a.id, a.check_in, a.check_out
  from attendance a
  where a.staff_id = (select id from current_staff())
    and not a.abandoned
  order by a.check_in desc limit 1;
$$;

-- ---------------------------------------------------------------
-- shifts
-- ---------------------------------------------------------------
create or replace function open_shift(p_opening_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  v_open  shifts;
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

  select * into v_open from shifts
   where staff_id = v_staff.id and closed_at is null and not abandoned
   order by opened_at desc limit 1;

  if v_open.id is not null then
    if (v_open.opened_at at time zone app_timezone())::date
       = (now() at time zone app_timezone())::date then
      return json_build_object('success', false, 'message', 'a shift is already open today');
    end if;

    -- A shift left open overnight can never yield a meter variance: nobody
    -- read the pump when they left. Marking it abandoned says exactly that,
    -- where inventing a closing meter would put a false variance into the
    -- one column that exists to catch missing fuel.
    update shifts set abandoned = true where id = v_open.id;
  end if;

  insert into shifts (station_id, staff_id, opening_meter, opened_at)
  values (v_staff.station_id, v_staff.id, p_opening_meter, now());

  return json_build_object('success', true, 'message', 'shift opened');
end; $$;

create or replace function close_shift(p_closing_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); v_id uuid; v_open numeric;
begin
  if v_staff.id is null then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if p_closing_meter is null or p_closing_meter < 0 then
    return json_build_object('success', false, 'message', 'enter the closing meter reading');
  end if;

  select id, opening_meter into v_id, v_open from shifts
   where staff_id = v_staff.id and closed_at is null and not abandoned
   order by opened_at desc limit 1;
  if v_id is null then return json_build_object('success', false, 'message', 'no open shift'); end if;

  -- A pump meter only counts up. A closing reading below the opening one is a
  -- typo, and accepting it would produce a negative variance that looks like
  -- fuel appearing out of nowhere.
  if p_closing_meter < v_open then
    return json_build_object('success', false,
      'message', 'the closing meter is below the opening one - check the reading');
  end if;

  update shifts set closing_meter = p_closing_meter, closed_at = now() where id = v_id;
  return json_build_object('success', true, 'message', 'shift closed');
end; $$;

create or replace function my_open_shift()
returns table (id uuid, opened_at timestamptz, opening_meter numeric)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.opened_at, sh.opening_meter
  from shifts sh
  where sh.staff_id = (select id from current_staff())
    and sh.closed_at is null and not sh.abandoned
  order by sh.opened_at desc limit 1;
$$;


