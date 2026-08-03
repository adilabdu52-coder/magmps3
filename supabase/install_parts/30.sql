-- MAGPMS install 30 of 44 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Nozzles, part 4: selling from a pump. record_sale changes signature, so
-- the old one is dropped first.
set search_path = public, extensions;
-- ---------------------------------------------------------------
-- selling, from a nozzle
-- ---------------------------------------------------------------
drop function if exists record_sale(text, numeric, text, uuid);

create or replace function record_sale(
  p_nozzle_id uuid, p_liters numeric, p_payment text,
  p_credit_customer_id uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  v_noz   nozzles;
  v_price numeric;
  v_tank  int;
  v_fuel  text;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if v_staff.station_id is null then
    return json_build_object('success', false, 'message', 'no branch assigned');
  end if;
  if not (p_liters > 0) then
    return json_build_object('success', false, 'message', 'litres must be positive');
  end if;

  select * into v_noz from nozzles where id = p_nozzle_id;
  if v_noz.id is null or v_noz.station_id <> v_staff.station_id then
    return json_build_object('success', false, 'message', 'choose a nozzle at this branch');
  end if;

  -- The shift must be theirs AND on this nozzle. Selling from a pump you have
  -- not opened is how a meter reading stops matching what came out of it.
  if not exists (select 1 from shifts
                  where staff_id = v_staff.id and nozzle_id = p_nozzle_id
                    and closed_at is null and not abandoned) then
    return json_build_object('success', false, 'message', 'open a shift on this nozzle first');
  end if;

  -- The fuel is the nozzle's, not the seller's choice. A nozzle dispenses
  -- what it dispenses, and letting the till say otherwise is how stock and
  -- takings drift apart.
  v_fuel := v_noz.fuel_type;
  if v_fuel is null then
    return json_build_object('success', false, 'message', 'this nozzle has no fuel set - ask the manager');
  end if;

  select price_per_liter into v_price
    from fuel_prices where station_id = v_staff.station_id and fuel_type = v_fuel;
  if v_price is null then
    return json_build_object('success', false, 'message', 'no price set for ' || v_fuel);
  end if;

  if p_payment = 'credit' then
    if p_credit_customer_id is null then
      return json_build_object('success', false, 'message', 'choose a credit customer');
    end if;
    if not exists (select 1 from credit_customers
                    where id = p_credit_customer_id and station_id = v_staff.station_id) then
      return json_build_object('success', false, 'message', 'customer is not at this branch');
    end if;
  end if;

  select id into v_tank from tanks
   where station_id = v_staff.station_id and fuel_type = v_fuel
   order by current_liters desc limit 1;
  if v_tank is null then
    return json_build_object('success', false, 'message', 'no tank holds ' || v_fuel);
  end if;
  if (select current_liters from tanks where id = v_tank) < p_liters then
    return json_build_object('success', false, 'message', 'not enough stock in the tank');
  end if;

  insert into sales (station_id, staff_id, nozzle_id, fuel_type, liters, total_etb,
                     payment_method, credit_customer_id)
  values (v_staff.station_id, v_staff.id, p_nozzle_id, v_fuel, p_liters,
          round(p_liters * v_price, 2), p_payment, p_credit_customer_id);

  update tanks set current_liters = current_liters - p_liters where id = v_tank;

  if p_payment = 'credit' then
    update credit_customers set balance = balance + round(p_liters * v_price, 2)
     where id = p_credit_customer_id;
  end if;

  return json_build_object('success', true, 'message', 'sale recorded');
end; $$;


