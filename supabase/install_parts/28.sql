-- MAGPMS install 28 of 29 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Nozzles, part 2: opening and closing a shift on a pump, and selling
-- from it. open_shift, close_shift and record_sale change signature, so
-- the old ones are dropped first.
set search_path = public, extensions;
-- ---------------------------------------------------------------
-- shifts, now against a nozzle
-- ---------------------------------------------------------------
drop function if exists open_shift(numeric);
drop function if exists close_shift(numeric);

create or replace function open_shift(p_nozzle_id uuid, p_opening_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  v_noz   nozzles;
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

  select * into v_noz from nozzles where id = p_nozzle_id;
  if v_noz.id is null then
    return json_build_object('success', false, 'message', 'choose a nozzle');
  end if;
  -- A nozzle at another branch is not theirs to open, whatever the app sent.
  if v_noz.station_id <> v_staff.station_id then
    return json_build_object('success', false, 'message', 'that nozzle is at another branch');
  end if;
  if not v_noz.active then
    return json_build_object('success', false, 'message', 'that nozzle is out of service');
  end if;

  -- Somebody else already on this pump.
  select * into v_open from shifts
   where nozzle_id = p_nozzle_id and closed_at is null and not abandoned
   order by opened_at desc limit 1;

  if v_open.id is not null then
    if (v_open.opened_at at time zone app_timezone())::date
       = (now() at time zone app_timezone())::date then
      return json_build_object('success', false,
        'message', case when v_open.staff_id = v_staff.id
                        then 'you already have this nozzle open'
                        else 'somebody else has this nozzle open' end);
    end if;
    -- Left open overnight: no closing meter was ever read, so no variance can
    -- exist for it. Mark it rather than invent one.
    update shifts set abandoned = true where id = v_open.id;
  end if;

  insert into shifts (station_id, staff_id, nozzle_id, opening_meter, opened_at)
  values (v_staff.station_id, v_staff.id, p_nozzle_id, p_opening_meter, now());

  return json_build_object('success', true, 'message', 'shift opened on ' || v_noz.label);
end; $$;

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
  if sh.staff_id <> v_staff.id then
    return json_build_object('success', false, 'message', 'that is not your shift');
  end if;
  if sh.closed_at is not null or sh.abandoned then
    return json_build_object('success', false, 'message', 'that shift is already closed');
  end if;

  -- A pump meter only counts up. A lower closing reading is a typo, and
  -- accepting it would show fuel appearing out of nowhere.
  if p_closing_meter < sh.opening_meter then
    return json_build_object('success', false,
      'message', 'the closing meter is below the opening one - check the reading');
  end if;

  update shifts set closing_meter = p_closing_meter, closed_at = now() where id = sh.id;
  return json_build_object('success', true, 'message', 'shift closed');
end; $$;

-- Plural: one person may be on two pumps at once, which is the whole point.
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
    left join nozzles n on n.id = sh.nozzle_id
   where sh.staff_id = (select id from current_staff())
     and sh.closed_at is null and not sh.abandoned
   order by sh.opened_at;
$$;

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


