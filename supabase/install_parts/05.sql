-- MAGPMS install 5 of 23 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

do $$
declare
  v_col text;
  v_admin uuid := (select id from staff where role = 'admin' order by created_at limit 1);
begin
  select column_name into v_col
    from information_schema.columns
   where table_schema = 'public' and table_name = 'fuel_prices'
     and column_name in ('price_per_liter','price','price_etb','unit_price')
   order by case column_name
              when 'price_per_liter' then 1 when 'price' then 2
              when 'price_etb' then 3 else 4 end
   limit 1;

  if v_col is null then
    raise notice 'could not find a price column on fuel_prices - seed skipped';
    return;
  end if;

  execute format($f$
    insert into price_history (station_id, fuel_type, old_price, new_price, changed_by)
    select p.station_id, p.fuel_type, null, p.%I, %L
      from fuel_prices p
     where not exists (
       select 1 from price_history h
        where h.station_id = p.station_id and h.fuel_type = p.fuel_type)
  $f$, v_col, v_admin);

  raise notice 'seeded price_history from fuel_prices.%', v_col;
end $$;

do $$
declare
  missing text := '';
  procedure_note text := 'adjust the function bodies below to match, then re-run';
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='fuel_prices'
                    and column_name='price_per_liter') then
    missing := missing || E'\n  fuel_prices.price_per_liter';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='tanks'
                    and column_name='current_liters') then
    missing := missing || E'\n  tanks.current_liters';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='sales'
                    and column_name='total_etb') then
    missing := missing || E'\n  sales.total_etb';
  end if;

  if missing <> '' then
    raise exception E'These columns are not what 0004 expects:%s\n\n%s\n\nList the real ones with:\n  select table_name, column_name from information_schema.columns\n  where table_schema=''public'' and table_name in (''fuel_prices'',''tanks'',''sales'')\n  order by table_name, ordinal_position;',
      missing, procedure_note;
  end if;
end $$;

create or replace function me()
returns table (id uuid, full_name text, email text, phone text,
               role text, status text, station_id uuid, station_name text)
language sql stable security definer set search_path = public
as $$
  select s.id, s.full_name, s.email, s.phone, s.role, s.status,
         s.station_id, st.name
  from current_staff() s
  left join stations st on st.id = s.station_id;
$$;
