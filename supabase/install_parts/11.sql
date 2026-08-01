-- MAGPMS install 11 of 37 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

create or replace function admin_list_staff()
returns table (id uuid, full_name text, email text, phone text, role text,
               status text, station_id uuid)
language sql stable security definer set search_path = public
as $$
  select s.id, s.full_name, s.email, s.phone, s.role, s.status, s.station_id
  from staff s where is_admin()
  order by s.status, s.full_name;
$$;

create or replace function admin_set_staff_status(p_staff_id uuid, p_status text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if p_status not in ('pending','approved','rejected') then
    return json_build_object('success', false, 'message', 'unknown status');
  end if;
  update staff set status = p_status where id = p_staff_id;
  return json_build_object('success', true, 'message', 'staff ' || p_status);
end; $$;

create or replace function admin_set_staff_role(p_staff_id uuid, p_role text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if p_role not in ('operator','accountant','manager','admin') then
    return json_build_object('success', false, 'message', 'unknown role');
  end if;
  -- never leave the group with no admin
  if p_role <> 'admin'
     and (select role from staff where id = p_staff_id) = 'admin'
     and (select count(*) from staff where role = 'admin' and status = 'approved') <= 1 then
    return json_build_object('success', false, 'message', 'cannot remove the last admin');
  end if;
  update staff set role = p_role where id = p_staff_id;
  return json_build_object('success', true, 'message', 'role updated');
end; $$;

create or replace function admin_set_staff_station(p_staff_id uuid, p_station_id uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  update staff set station_id = p_station_id where id = p_staff_id;
  return json_build_object('success', true, 'message', 'branch assigned');
end; $$;

create or replace function admin_record_delivery(p_tank_id int, p_liters numeric)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if not (p_liters > 0) then return json_build_object('success', false, 'message', 'litres must be positive'); end if;
  if (select current_liters + p_liters > capacity_liters from tanks where id = p_tank_id) then
    return json_build_object('success', false, 'message', 'delivery exceeds tank capacity');
  end if;
  update tanks set current_liters = current_liters + p_liters where id = p_tank_id;
  return json_build_object('success', true, 'message', 'delivery recorded');
end; $$;

create or replace function admin_add_credit_customer(
  p_station_id uuid, p_name text, p_phone text default null,
  p_plate text default null, p_limit numeric default 0)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  insert into credit_customers (station_id, name, phone, plate_no, credit_limit, balance)
  values (p_station_id, p_name, p_phone, p_plate, coalesce(p_limit, 0), 0);
  return json_build_object('success', true, 'message', 'customer added');
end; $$;
