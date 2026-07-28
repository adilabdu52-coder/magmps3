-- 0003 — price history
--
-- The old admin_set_price upserted in place, so every previous price was
-- overwritten and unrecoverable. There is no way to answer "what did we
-- charge on the 4th?" after the fact. This adds an append-only trail.

begin;

create table if not exists price_history (
  id          uuid primary key default gen_random_uuid(),
  station_id  uuid not null references stations(id),
  fuel_type   text not null,
  old_price   numeric,                      -- null on the first ever set
  new_price   numeric not null,
  changed_by  uuid not null references staff(id),
  changed_at  timestamptz not null default now()
);

create index if not exists price_history_lookup_idx
  on price_history (station_id, fuel_type, changed_at desc);

-- Append-only: a wrong price is corrected by a new row, never by editing an
-- old one. An audit trail you can rewrite is not an audit trail.
revoke update, delete on price_history from authenticated, anon;

-- Seed the trail with whatever the prices table currently holds, so the
-- history does not start empty and the first real change has something to
-- compare against.
insert into price_history (station_id, fuel_type, old_price, new_price, changed_by, changed_at)
select p.station_id, p.fuel_type, null, p.price_per_liter,
       (select id from staff where role = 'admin' order by created_at limit 1),
       coalesce(p.updated_at, now())          -- ⚠ verify prices.updated_at exists
from prices p
where not exists (
  select 1 from price_history h
  where h.station_id = p.station_id and h.fuel_type = p.fuel_type
);

commit;

-- RELATED BUG, worth fixing while you are here:
--   If sales join to prices at read time, every past receipt silently
--   re-prices whenever the pump price changes. Sales should store the price
--   they were sold at:
--
--     ALTER TABLE sales ADD COLUMN price_per_liter numeric;
--     UPDATE sales s SET price_per_liter = ROUND(s.total_etb / NULLIF(s.liters,0), 2)
--       WHERE s.price_per_liter IS NULL AND s.liters > 0;
--     ALTER TABLE sales ALTER COLUMN price_per_liter SET NOT NULL;
