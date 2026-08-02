-- MAGPMS install 9 of 39 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

create or replace function record_sale(
  p_fuel_type text, p_liters numeric, p_payment text,
  p_credit_customer_id uuid default null)
returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_staff staff := current_staff();
  v_station uuid;
  v_price numeric;
  v_tank int;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  v_station := v_staff.station_id;
  if v_station is null then
    return json_build_object('success', false, 'message', 'no branch assigned');
  end if;
  if not exists (select 1 from shifts where staff_id = v_staff.id and closed_at is null) then
    return json_build_object('success', false, 'message', 'open a shift first');
  end if;
  if not (p_liters > 0) then
    return json_build_object('success', false, 'message', 'litres must be positive');
  end if;

  select price_per_liter into v_price
  from fuel_prices where station_id = v_station and fuel_type = p_fuel_type;
  if v_price is null then
    return json_build_object('success', false, 'message', 'no price set for ' || p_fuel_type);
  end if;

  -- credit customers belong to one branch
  if p_payment = 'credit' then
    if p_credit_customer_id is null then
      return json_build_object('success', false, 'message', 'choose a credit customer');
    end if;
    if not exists (select 1 from credit_customers
                   where id = p_credit_customer_id and station_id = v_station) then
      return json_build_object('success', false, 'message', 'customer is not at this branch');
    end if;
  end if;

  select id into v_tank from tanks
  where station_id = v_station and fuel_type = p_fuel_type
  order by current_liters desc limit 1;
  if v_tank is null then
    return json_build_object('success', false, 'message', 'no tank holds ' || p_fuel_type);
  end if;
  if (select current_liters from tanks where id = v_tank) < p_liters then
    return json_build_object('success', false, 'message', 'not enough stock in the tank');
  end if;

  insert into sales (station_id, staff_id, fuel_type, liters, total_etb,
                     payment_method, credit_customer_id)
  values (v_station, v_staff.id, p_fuel_type, p_liters, round(p_liters * v_price, 2),
          p_payment, p_credit_customer_id);

  update tanks set current_liters = current_liters - p_liters where id = v_tank;

  if p_payment = 'credit' then
    update credit_customers set balance = balance + round(p_liters * v_price, 2)
    where id = p_credit_customer_id;
  end if;

  return json_build_object('success', true, 'message', 'sale recorded');
end;
$$;
