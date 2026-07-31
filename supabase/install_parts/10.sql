-- MAGPMS install 10 of 20 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

create or replace function open_shift(p_opening_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff();
begin
  if v_staff.id is null then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if exists (select 1 from shifts where staff_id = v_staff.id and closed_at is null) then
    return json_build_object('success', false, 'message', 'a shift is already open');
  end if;
  insert into shifts (station_id, staff_id, opening_meter, opened_at)
  values (v_staff.station_id, v_staff.id, p_opening_meter, now());
  return json_build_object('success', true, 'message', 'shift opened');
end; $$;

create or replace function close_shift(p_closing_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); v_id uuid;
begin
  select id into v_id from shifts
  where staff_id = v_staff.id and closed_at is null order by opened_at desc limit 1;
  if v_id is null then return json_build_object('success', false, 'message', 'no open shift'); end if;
  update shifts set closing_meter = p_closing_meter, closed_at = now() where id = v_id;
  return json_build_object('success', true, 'message', 'shift closed');
end; $$;

create or replace function check_in()
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff();
begin
  if v_staff.id is null then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if exists (select 1 from attendance where staff_id = v_staff.id and check_out is null) then
    return json_build_object('success', false, 'message', 'already checked in');
  end if;
  insert into attendance (station_id, staff_id, check_in)
  values (v_staff.station_id, v_staff.id, now());
  return json_build_object('success', true, 'message', 'checked in');
end; $$;

create or replace function check_out()
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); v_id uuid;
begin
  select id into v_id from attendance
  where staff_id = v_staff.id and check_out is null order by check_in desc limit 1;
  if v_id is null then return json_build_object('success', false, 'message', 'not checked in'); end if;
  update attendance set check_out = now() where id = v_id;
  return json_build_object('success', true, 'message', 'checked out');
end; $$;

create or replace function admin_set_price(p_station_id uuid, p_fuel_type text, p_price numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_admin staff := current_staff(); v_old numeric;
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if not (p_price > 0) then return json_build_object('success', false, 'message', 'price must be positive'); end if;

  select price_per_liter into v_old
  from fuel_prices where station_id = p_station_id and fuel_type = p_fuel_type;

  insert into fuel_prices (station_id, fuel_type, price_per_liter)
  values (p_station_id, p_fuel_type, p_price)
  on conflict (station_id, fuel_type)
  do update set price_per_liter = excluded.price_per_liter;

  -- price and history are written together, so the trail cannot miss a change
  insert into price_history (station_id, fuel_type, old_price, new_price, changed_by)
  values (p_station_id, p_fuel_type, v_old, p_price, v_admin.id);

  return json_build_object('success', true, 'message', 'price updated');
end; $$;
