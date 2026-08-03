-- MAGPMS install 32 of 44 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- The manager can close a pump a cashier left open, with the reading they
-- take, and the row records who closed it.
set search_path = public, extensions;
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


