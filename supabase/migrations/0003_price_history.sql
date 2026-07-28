-- 0003 — price history
--
-- The old admin_set_price(uuid, text, numeric) upserted in place, so every
-- previous price was overwritten and unrecoverable. There is no way to answer
-- "what did we charge on the 4th?" after the fact. This adds an append-only
-- trail against fuel_prices.

begin;

create table if not exists price_history (
  id          uuid primary key default gen_random_uuid(),
  station_id  uuid not null references stations(id),
  fuel_type   text not null,
  old_price   numeric,                      -- null on the first ever set
  new_price   numeric not null,
  changed_by  uuid references staff(id),    -- nullable: seeded rows have no author
  changed_at  timestamptz not null default now()
);

create index if not exists price_history_lookup_idx
  on price_history (station_id, fuel_type, changed_at desc);

-- Append-only: a wrong price is corrected by a new row, never by editing an
-- old one. An audit trail you can rewrite is not an audit trail.
revoke update, delete on price_history from authenticated, anon;

commit;

-- ---------------------------------------------------------------
-- seed the trail from whatever fuel_prices holds today
-- ---------------------------------------------------------------
-- So the history does not start empty and the first real change has something
-- to compare against. The price column name is discovered rather than assumed.
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

-- ---------------------------------------------------------------
-- RELATED BUG, worth fixing while you are here
-- ---------------------------------------------------------------
-- If sales join to fuel_prices at read time, every past receipt silently
-- re-prices whenever the pump price changes. Sales should store the price
-- they were sold at:
--
--   alter table sales add column if not exists price_per_liter numeric;
--   update sales set price_per_liter = round(total_etb / nullif(liters,0), 2)
--    where price_per_liter is null and liters > 0;
--
-- Left commented because it depends on sales having total_etb and liters
-- under those names - check before running.
