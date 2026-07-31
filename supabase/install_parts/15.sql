-- MAGPMS install 15 of 18 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

create or replace function list_deliveries(p_station_id uuid default null, p_limit int default 50)
returns table (id uuid, station_id uuid, station_name text, tank_name text,
               fuel_type text, liters numeric, note text,
               recorded_by_name text, created_at timestamptz)
language plpgsql stable security definer set search_path = public
as $$
declare v_qty text; v_tank text;
begin
  select column_name into v_qty from information_schema.columns
   where table_schema='public' and table_name='deliveries'
     and column_name in ('liters','litres','liters_delivered','quantity','amount')
   order by case column_name when 'liters' then 1 when 'litres' then 2 else 3 end limit 1;
  select column_name into v_tank from information_schema.columns
   where table_schema='public' and table_name='deliveries'
     and column_name in ('tank_id','tank') limit 1;

  return query execute format($f$
    select d.id, d.station_id, st.name, t.tank_name, t.fuel_type,
           d.%I, d.note, s.full_name, d.created_at
      from deliveries d
      join stations st on st.id = d.station_id
      left join tanks t on t.id = d.%I
      left join staff s on s.id = d.recorded_by
     where d.station_id = case when is_admin() then coalesce(%L::uuid, d.station_id)
                               else current_station() end
     order by d.created_at desc
     limit %s
  $f$, v_qty, v_tank, p_station_id, greatest(1, least(p_limit, 500)));
end;
$$;

drop function if exists admin_record_delivery(uuid, int, numeric, text);

drop function if exists admin_record_delivery(int, numeric);

create or replace function list_shifts(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text,
  opened_at timestamptz, closed_at timestamptz,
  opening_meter numeric, closing_meter numeric,
  metered_liters numeric, sold_liters numeric, variance_liters numeric)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.station_id, st.name, stf.full_name,
         sh.opened_at, sh.closed_at, sh.opening_meter, sh.closing_meter,
         case when sh.closing_meter is null then null
              else sh.closing_meter - sh.opening_meter end,
         coalesce(sold.liters, 0),
         case when sh.closing_meter is null then null
              else (sh.closing_meter - sh.opening_meter) - coalesce(sold.liters, 0) end
    from shifts sh
    join stations st on st.id = sh.station_id
    left join staff stf on stf.id = sh.staff_id
    left join lateral (
      select sum(s.liters) as liters
        from sales s
       where s.staff_id = sh.staff_id
         and not coalesce(s.voided, false)
         and s.created_at >= sh.opened_at
         and s.created_at <  coalesce(sh.closed_at, now())
    ) sold on true
   where sh.station_id = case when is_admin() then coalesce(p_station_id, sh.station_id)
                              else current_station() end
     and sh.opened_at >= now() - make_interval(days => greatest(1, p_days))
   order by sh.opened_at desc
   limit greatest(1, least(p_limit, 500));
$$;
