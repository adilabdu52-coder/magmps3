-- 0006 — record deliveries, not just their effect
--
-- 0004's admin_record_delivery only adjusted tanks.current_liters. The stock
-- level came out right, but nothing recorded who delivered what, when, or to
-- which tank - and the database already has a `deliveries` table for exactly
-- that. The old signature, admin_record_delivery(uuid, int, numeric, text),
-- took a fourth text argument that was almost certainly a note, which suggests
-- it wrote there.
--
-- This makes the tank update and the delivery record one transaction, the same
-- way admin_set_price and price_history are written together. A stock level
-- that cannot be traced back to a delivery is how discrepancies become
-- arguments.
--
-- The column names on `deliveries` are discovered rather than assumed, so this
-- adapts to whatever shape the table already has.

begin;

-- Make sure the table exists and carries a station, whatever else it has.
do $$
begin
  if to_regclass('public.deliveries') is null then
    create table deliveries (
      id          uuid primary key default gen_random_uuid(),
      station_id  uuid not null references stations(id),
      tank_id     int  not null,
      liters      numeric not null,
      note        text,
      recorded_by uuid references staff(id),
      created_at  timestamptz not null default now()
    );
    raise notice 'created deliveries';
  end if;
end $$;

alter table deliveries add column if not exists station_id  uuid references stations(id);
alter table deliveries add column if not exists recorded_by uuid references staff(id);
alter table deliveries add column if not exists note        text;

create index if not exists deliveries_station_created_idx
  on deliveries (station_id, created_at desc);

commit;

-- ---------------------------------------------------------------
-- the function, built around the columns that are actually there
-- ---------------------------------------------------------------
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

-- ---------------------------------------------------------------
-- read it back
-- ---------------------------------------------------------------
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

-- The old four-argument version is superseded.
drop function if exists admin_record_delivery(uuid, int, numeric, text);
drop function if exists admin_record_delivery(int, numeric);
