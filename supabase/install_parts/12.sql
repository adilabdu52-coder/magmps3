-- MAGPMS install 12 of 20 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

create or replace function admin_credit_payment(p_customer_id uuid, p_amount numeric)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if not (p_amount > 0) then return json_build_object('success', false, 'message', 'amount must be positive'); end if;
  update credit_customers set balance = greatest(0, balance - p_amount) where id = p_customer_id;
  return json_build_object('success', true, 'message', 'payment recorded');
end; $$;

create or replace function admin_add_expense(
  p_station_id uuid, p_category text, p_amount numeric, p_description text default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  insert into expenses (station_id, category, description, amount_etb)
  values (p_station_id, p_category, p_description, p_amount);
  return json_build_object('success', true, 'message', 'expense added');
end; $$;

create or replace function admin_void_sale(p_sale_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare s sales; v_tank int;
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  select * into s from sales where id = p_sale_id;
  if s.id is null then return json_build_object('success', false, 'message', 'sale not found'); end if;
  if coalesce(s.voided,false) then return json_build_object('success', false, 'message', 'already voided'); end if;

  update sales set voided = true where id = p_sale_id;

  -- put the fuel back into the emptiest matching tank at that branch
  select id into v_tank from tanks
  where station_id = s.station_id and fuel_type = s.fuel_type
  order by current_liters limit 1;
  if v_tank is not null then
    update tanks set current_liters = current_liters + s.liters where id = v_tank;
  end if;

  if s.payment_method = 'credit' and s.credit_customer_id is not null then
    update credit_customers set balance = greatest(0, balance - s.total_etb)
    where id = s.credit_customer_id;
  end if;

  return json_build_object('success', true, 'message', 'sale voided');
end; $$;

drop function if exists login_staff(text,text);

drop function if exists login_admin(text,text);

drop function if exists create_first_admin(text,text,text);

drop function if exists register_staff(text,text,text,text);

drop function if exists admin_list_staff(text);

drop function if exists admin_set_staff_status(uuid,uuid,text);

drop function if exists admin_set_staff_role(uuid,uuid,text);

drop function if exists record_sale(uuid,text,numeric,numeric,text);

drop function if exists record_sale_v2(uuid,text,numeric,text,uuid);

drop function if exists list_tanks();

drop function if exists get_prices();

drop function if exists open_shift(uuid,numeric);

drop function if exists close_shift(uuid,numeric);

drop function if exists my_open_shift(uuid);

drop function if exists admin_record_delivery(uuid,int,numeric,text);

drop function if exists list_credit_customers();

drop function if exists admin_credit_payment(uuid,uuid,numeric);

drop function if exists admin_add_expense(uuid,text,text,numeric);

drop function if exists list_expenses(int);

drop function if exists admin_void_sale(uuid,uuid);

drop function if exists check_in(uuid);

drop function if exists check_out(uuid);

drop function if exists my_attendance_status(uuid);
