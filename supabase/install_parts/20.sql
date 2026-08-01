-- MAGPMS install 20 of 33 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Four functions ran an update keyed on an id and then reported success
-- without checking whether the update matched a row. An approval that
-- changed nothing still showed a green toast. This makes them say so.
set search_path = public, extensions;
-- ---------------------------------------------------------------
-- staff status - the one that was actually caught
-- ---------------------------------------------------------------
create or replace function admin_set_staff_status(p_staff_id uuid, p_status text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if p_status not in ('pending','approved','rejected') then
    return json_build_object('success', false, 'message', 'unknown status');
  end if;

  update staff set status = p_status where id = p_staff_id;
  if not found then
    return json_build_object('success', false, 'message', 'no such staff member');
  end if;

  return json_build_object('success', true, 'message', 'staff ' || p_status);
end; $$;

-- ---------------------------------------------------------------
-- staff role
-- ---------------------------------------------------------------
-- The last-admin guard stays exactly as it was. It reads the row before
-- deciding, so it already fails safe on a bad id - a missing row is not an
-- admin, so the guard passes and the update then matches nothing. That is
-- what the new check catches.
create or replace function admin_set_staff_role(p_staff_id uuid, p_role text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if p_role not in ('operator','accountant','manager','admin') then
    return json_build_object('success', false, 'message', 'unknown role');
  end if;
  if p_role <> 'admin'
     and (select role from staff where id = p_staff_id) = 'admin'
     and (select count(*) from staff where role = 'admin' and status = 'approved') <= 1 then
    return json_build_object('success', false, 'message', 'cannot remove the last admin');
  end if;

  update staff set role = p_role where id = p_staff_id;
  if not found then
    return json_build_object('success', false, 'message', 'no such staff member');
  end if;

  return json_build_object('success', true, 'message', 'role updated');
end; $$;

-- ---------------------------------------------------------------
-- staff branch
-- ---------------------------------------------------------------
-- p_station_id null is legitimate and means "no branch" - that is how a
-- central admin sees all five. So null is not an error here; only a staff id
-- that matches nothing is.
create or replace function admin_set_staff_station(p_staff_id uuid, p_station_id uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;

  if p_station_id is not null
     and not exists (select 1 from stations where id = p_station_id) then
    return json_build_object('success', false, 'message', 'no such branch');
  end if;

  update staff set station_id = p_station_id where id = p_staff_id;
  if not found then
    return json_build_object('success', false, 'message', 'no such staff member');
  end if;

  return json_build_object('success', true,
    'message', case when p_station_id is null then 'branch cleared' else 'branch assigned' end);
end; $$;

-- ---------------------------------------------------------------
-- credit payment
-- ---------------------------------------------------------------
-- Money. A payment recorded against an id that does not exist would report
-- "payment recorded" while the customer's balance stayed exactly where it
-- was - and the next person to look would see a debt the customer believes
-- they have already paid.
create or replace function admin_credit_payment(p_customer_id uuid, p_amount numeric)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if not (p_amount > 0) then return json_build_object('success', false, 'message', 'amount must be positive'); end if;

  update credit_customers set balance = greatest(0, balance - p_amount) where id = p_customer_id;
  if not found then
    return json_build_object('success', false, 'message', 'no such customer');
  end if;

  return json_build_object('success', true, 'message', 'payment recorded');
end; $$;



notify pgrst, 'reload schema';


