-- MAGPMS install 14 of 33 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

do $$
declare
  v_qty  text;   -- litres column
  v_tank text;   -- tank reference column
  v_body text;
begin
  select column_name into v_qty from information_schema.columns
   where table_schema='public' and table_name='deliveries'
     and column_name in ('liters','litres','liters_delivered','quantity','amount')
   order by case column_name when 'liters' then 1 when 'litres' then 2 else 3 end
   limit 1;

  select column_name into v_tank from information_schema.columns
   where table_schema='public' and table_name='deliveries'
     and column_name in ('tank_id','tank')
   limit 1;

  if v_qty is null or v_tank is null then
    raise exception
      E'deliveries is missing a quantity or tank column.\nFound neither of the expected names. List them with:\n  select column_name from information_schema.columns\n  where table_schema=''public'' and table_name=''deliveries'';';
  end if;

  v_body := format($f$
    create or replace function admin_record_delivery(
      p_tank_id int, p_liters numeric, p_note text default null)
    returns json
    language plpgsql security definer set search_path = public
    as $body$
    declare
      v_admin staff := current_staff();
      v_station uuid;
    begin
      if not is_admin() then
        return json_build_object('success', false, 'message', 'not authorised');
      end if;
      if not (p_liters > 0) then
        return json_build_object('success', false, 'message', 'litres must be positive');
      end if;

      select station_id into v_station from tanks where id = p_tank_id;
      if v_station is null then
        return json_build_object('success', false, 'message', 'tank not found');
      end if;
      if (select current_liters + p_liters > capacity_liters from tanks where id = p_tank_id) then
        return json_build_object('success', false, 'message', 'delivery exceeds tank capacity');
      end if;

      update tanks set current_liters = current_liters + p_liters where id = p_tank_id;

      insert into deliveries (station_id, %I, %I, note, recorded_by)
      values (v_station, p_tank_id, p_liters, p_note, v_admin.id);

      return json_build_object('success', true, 'message', 'delivery recorded');
    end;
    $body$;
  $f$, v_tank, v_qty);

  execute v_body;
  raise notice 'admin_record_delivery now writes deliveries.% / deliveries.%', v_tank, v_qty;
end $$;
