-- MAGPMS install 6 of 39 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

create or replace function register_staff(p_full_name text, p_phone text default null)
returns json
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return json_build_object('success', false, 'message', 'not authenticated');
  end if;
  if exists (select 1 from staff where auth_user_id = v_uid) then
    return json_build_object('success', false, 'message', 'account already registered');
  end if;

  insert into staff (auth_user_id, full_name, phone, email, role, status)
  values (v_uid, p_full_name, p_phone,
          (select email from auth.users where id = v_uid), 'operator', 'pending');

  return json_build_object('success', true, 'message', 'awaiting admin approval');
end;
$$;

create or replace function list_stations()
returns table (id uuid, name text, town text)
language sql stable security definer set search_path = public
as $$
  select s.id, s.name, s.town from stations s
  where is_admin() or s.id = current_station()
  order by s.name;
$$;

create or replace function admin_dashboard()
returns table (
  station_id uuid, station_name text, town text,
  sales_today_etb numeric, liters_today numeric,
  stock_liters numeric, capacity_liters numeric,
  credit_etb numeric, on_duty int, low_tanks int
)
language sql stable security definer set search_path = public
as $$
  select st.id, st.name, st.town,
    coalesce((select sum(s.total_etb) from sales s
              where s.station_id = st.id and not coalesce(s.voided,false)
                and s.created_at >= date_trunc('day', now())), 0),
    coalesce((select sum(s.liters) from sales s
              where s.station_id = st.id and not coalesce(s.voided,false)
                and s.created_at >= date_trunc('day', now())), 0),
    coalesce((select sum(t.current_liters)  from tanks t where t.station_id = st.id), 0),
    coalesce((select sum(t.capacity_liters) from tanks t where t.station_id = st.id), 0),
    coalesce((select sum(c.balance) from credit_customers c where c.station_id = st.id), 0),
    coalesce((select count(*)::int from attendance a
              where a.station_id = st.id and a.check_out is null), 0),
    coalesce((select count(*)::int from tanks t
              where t.station_id = st.id and t.capacity_liters > 0
                and (t.current_liters / t.capacity_liters) < 0.30), 0)
  from stations st
  where is_admin() or st.id = current_station()
  order by st.name;
$$;

create or replace function get_prices(p_station_id uuid default null)
returns table (fuel_type text, price_per_liter numeric)
language sql stable security definer set search_path = public
as $$
  select p.fuel_type, p.price_per_liter
  from fuel_prices p
  where p.station_id = case when is_admin() then coalesce(p_station_id, p.station_id)
                            else current_station() end
  order by p.fuel_type;
$$;
