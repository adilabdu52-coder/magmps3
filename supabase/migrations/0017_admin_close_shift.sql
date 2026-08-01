-- 0017 — the manager can close a pump, and the record says who did
--
-- close_shift refuses unless the caller opened the shift. That is right for a
-- cashier: closing somebody else's pump would put your meter reading against
-- their name. But it left the manager with no way to close anything.
--
-- A cashier who goes home without closing leaves a shift open with no route
-- out. 0015's abandoned mechanism catches it the NEXT day, and marks it as
-- having no variance at all - which is the honest answer when nobody read the
-- pump. But when the manager IS standing at the pump and CAN read it, the
-- variance is knowable, and throwing it away for want of a button is a waste
-- of the one number this whole feature exists to produce.
--
-- So: an admin may close any shift, with the reading they took. And the row
-- records who closed it, because "closed by the person who worked it" and
-- "closed by the manager the next morning" are different facts and should not
-- look identical in a week's time.

begin;

alter table shifts add column if not exists closed_by uuid references staff(id);

-- Fill in what we can for shifts already closed: a shift closed before this
-- existed was closed by its own operator, because that was the only way.
update shifts set closed_by = staff_id
 where closed_at is not null and closed_by is null;

create or replace function close_shift(p_shift_id uuid, p_closing_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); sh shifts;
begin
  if v_staff.id is null then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if p_closing_meter is null or p_closing_meter < 0 then
    return json_build_object('success', false, 'message', 'enter the closing meter reading');
  end if;

  select * into sh from shifts where id = p_shift_id;
  if sh.id is null then return json_build_object('success', false, 'message', 'no such shift'); end if;

  -- An admin may close anyone's; a cashier only their own.
  if sh.staff_id <> v_staff.id and not is_admin() then
    return json_build_object('success', false, 'message', 'that is not your shift');
  end if;
  if sh.closed_at is not null or sh.abandoned then
    return json_build_object('success', false, 'message', 'that shift is already closed');
  end if;
  if p_closing_meter < sh.opening_meter then
    return json_build_object('success', false,
      'message', 'the closing meter is below the opening one - check the reading');
  end if;

  update shifts
     set closing_meter = p_closing_meter, closed_at = now(), closed_by = v_staff.id
   where id = sh.id;

  return json_build_object('success', true,
    'message', case when sh.staff_id = v_staff.id then 'shift closed'
                    else 'shift closed for them' end);
end; $$;

-- ---------------------------------------------------------------
-- and say so in the list
-- ---------------------------------------------------------------
drop function if exists list_shifts(uuid, int, int);

create or replace function list_shifts(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text, nozzle_label text,
  opened_at timestamptz, closed_at timestamptz,
  opening_meter numeric, closing_meter numeric,
  metered_liters numeric, sold_liters numeric, variance_liters numeric,
  abandoned boolean, closed_by_other boolean)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.station_id, coalesce(st.name, '(no branch)'), stf.full_name,
         coalesce(n.label, '-'),
         sh.opened_at, sh.closed_at, sh.opening_meter, sh.closing_meter,
         case when sh.closing_meter is null then null
              else sh.closing_meter - sh.opening_meter end,
         coalesce(sold.liters, 0),
         case when sh.closing_meter is null then null
              else (sh.closing_meter - sh.opening_meter) - coalesce(sold.liters, 0) end,
         sh.abandoned,
         -- A variance from a meter the operator never read is worth less than
         -- one they did. The column says which, rather than leaving both
         -- looking the same a week later.
         (sh.closed_by is not null and sh.closed_by <> sh.staff_id)
    from shifts sh
    left join stations st on st.id = sh.station_id
    left join staff stf on stf.id = sh.staff_id
    left join nozzles n on n.id = sh.nozzle_id
    left join lateral (
      select sum(s.liters) as liters
        from sales s
       where s.nozzle_id is not distinct from sh.nozzle_id
         and s.staff_id = sh.staff_id
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

grant execute on function close_shift(uuid, numeric)  to authenticated;
grant execute on function list_shifts(uuid, int, int) to authenticated;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select staff_name, nozzle_label, variance_liters, closed_by_other
--     from list_shifts(null, 7, 200) where closed_at is not null;
--
-- closed_by_other is true only where somebody other than the operator took
-- the reading.
