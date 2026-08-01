-- 0015 — shifts and attendance that survive a forgotten check-out
--
-- Four faults, found by reading rather than by waiting for them again. They
-- reinforce each other, which is why the symptom was "attendance does not
-- work for the staff" rather than anything more specific.
--
-- 1. A FORGOTTEN CHECK-OUT LOCKS SOMEBODY OUT THE NEXT DAY.
--    check_in refuses if any attendance row is open - including one from last
--    Monday. So a cashier who forgets to check out cannot check in again,
--    ever, and the screen tells them "already checked in" over a time from
--    days ago. Same for open_shift: "a shift is already open".
--
--    This is not an edge case. Forgetting to check out at the end of a long
--    day is the single most likely thing a tired person does.
--
-- 2. A ROW WITH NO BRANCH IS INVISIBLE TO THE ADMIN, FOREVER.
--    open_shift and check_in write station_id from the staff row, which is
--    null for anyone not yet given a branch. list_shifts and list_attendance
--    then INNER JOIN stations, so those rows are dropped. The cashier sees
--    "Checked in"; the manager's page shows nothing, and neither of them has
--    any reason to doubt their own screen.
--
-- 3. HOURS GROW FOR EVER ON AN ABANDONED ROW.
--    list_attendance runs hours to now() when check_out is null. A forgotten
--    check-out reads as 200 hours by the following week - a number that is
--    not just wrong but actively misleading in a wage discussion.
--
-- 4. close_shift AND check_out NEVER CHECK WHO IS CALLING.
--    With no session they answer "no open shift" and "not checked in", which
--    sound like facts about the data rather than a refusal.
--
-- The approach for (1) and (3): a row left open from a previous day is marked
-- ABANDONED rather than given an invented check-out time. We do not know when
-- that person went home, and guessing puts a fabricated number into a record
-- that may settle an argument about pay one day. Abandoned rows stop blocking,
-- stop accumulating hours, and stay visible so somebody can ask.

begin;

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

-- ---------------------------------------------------------------
-- what the admin sees
-- ---------------------------------------------------------------
-- LEFT JOIN, so a row with no branch appears instead of vanishing. The branch
-- test is written out rather than folded into a coalesce, because
-- `station_id = coalesce(null, station_id)` is false when station_id is null -
-- which is exactly how those rows disappeared.
--
-- These two must be DROPPED first, not replaced. Both gain an `abandoned`
-- column, and Postgres refuses to change a function's return type in place:
--
--   ERROR: cannot change return type of existing function
--   HINT:  Use DROP FUNCTION list_shifts(uuid,integer,integer) first.
--
-- On a database that has never had 0007 this is a no-op, which is why running
-- against a fresh schema did not catch it. The upgrade path is the one that
-- matters, and it is the one everybody actually runs.
--
-- Dropping loses the grants that 0005 issued with `grant execute on all
-- functions`, so they are re-issued at the end of this file. A silent loss of
-- execute permission would show up as "permission denied for function" on
-- the shifts page and nowhere else.
drop function if exists list_shifts(uuid, int, int);
drop function if exists list_attendance(uuid, int, int);

create or replace function list_shifts(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text,
  opened_at timestamptz, closed_at timestamptz,
  opening_meter numeric, closing_meter numeric,
  metered_liters numeric, sold_liters numeric, variance_liters numeric,
  abandoned boolean)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.station_id, coalesce(st.name, '(no branch)'), stf.full_name,
         sh.opened_at, sh.closed_at, sh.opening_meter, sh.closing_meter,
         case when sh.closing_meter is null then null
              else sh.closing_meter - sh.opening_meter end,
         coalesce(sold.liters, 0),
         case when sh.closing_meter is null then null
              else (sh.closing_meter - sh.opening_meter) - coalesce(sold.liters, 0) end,
         sh.abandoned
    from shifts sh
    left join stations st on st.id = sh.station_id
    left join staff stf on stf.id = sh.staff_id
    left join lateral (
      select sum(s.liters) as liters
        from sales s
       where s.staff_id = sh.staff_id
         and not coalesce(s.voided, false)
         and s.created_at >= sh.opened_at
         and s.created_at <  coalesce(sh.closed_at, now())
    ) sold on true
   where (case when is_admin()
               then (p_station_id is null or sh.station_id = p_station_id)
               else sh.station_id = current_station() end)
     and sh.opened_at >= now() - make_interval(days => greatest(1, p_days))
   order by sh.opened_at desc
   limit greatest(1, least(p_limit, 500));
$$;

-- hours is null for an abandoned row. Nobody knows when that person went
-- home, and a number here would be read as if somebody did.
create or replace function list_attendance(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text,
  check_in timestamptz, check_out timestamptz, hours numeric, abandoned boolean)
language sql stable security definer set search_path = public
as $$
  select a.id, a.station_id, coalesce(st.name, '(no branch)'), stf.full_name,
         a.check_in, a.check_out,
         case when a.abandoned then null
              else round((extract(epoch from (coalesce(a.check_out, now()) - a.check_in))
                          / 3600.0)::numeric, 2) end,
         a.abandoned
    from attendance a
    left join stations st on st.id = a.station_id
    left join staff stf on stf.id = a.staff_id
   where (case when is_admin()
               then (p_station_id is null or a.station_id = p_station_id)
               else a.station_id = current_station() end)
     and a.check_in >= now() - make_interval(days => greatest(1, p_days))
   order by a.check_in desc
   limit greatest(1, least(p_limit, 500));
$$;

-- Re-issued because the two functions above were dropped and recreated, which
-- takes their permissions with them.
grant execute on function list_shifts(uuid, int, int)     to authenticated;
grant execute on function list_attendance(uuid, int, int) to authenticated;
grant execute on function check_in()                      to authenticated;
grant execute on function check_out()                     to authenticated;
grant execute on function open_shift(numeric)             to authenticated;
grant execute on function close_shift(numeric)            to authenticated;
grant execute on function my_open_shift()                 to authenticated;
grant execute on function my_attendance_status()          to authenticated;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- REPAIR: rows already stranded
-- ===============================================================
-- Anything left open from before today would still block its owner, since
-- the new rule only marks a stale row when they next try. This clears the
-- backlog in one go:
--
--   update attendance set abandoned = true
--    where check_out is null and not abandoned
--      and (check_in at time zone app_timezone())::date
--          < (now() at time zone app_timezone())::date
--   returning staff_id, check_in;
--
--   update shifts set abandoned = true
--    where closed_at is null and not abandoned
--      and (opened_at at time zone app_timezone())::date
--          < (now() at time zone app_timezone())::date
--   returning staff_id, opened_at;
--
-- Look at what comes back before running the second one: an open shift from
-- earlier today is somebody currently working, and today's rows are left
-- alone by the date test on purpose.
--
-- ===============================================================
-- VERIFY
-- ===============================================================
--   select count(*) as still_blocking
--     from attendance
--    where check_out is null and not abandoned
--      and (check_in at time zone app_timezone())::date
--          < (now() at time zone app_timezone())::date;
--
-- Expect 0, and expect it to stay 0 from now on.
