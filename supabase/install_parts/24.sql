-- MAGPMS install 24 of 33 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Backup: the whole database as one JSON document, with no row cap. The
-- listing functions all stop at 500 rows, which is why this reads the
-- tables directly instead of reusing them.
set search_path = public, extensions;
create or replace function admin_backup()
returns json
language sql stable security definer set search_path = public
as $$
  select case when not is_admin() then
    json_build_object('error', 'not authorised')
  else
    json_build_object(
      'magpms_backup_version', 1,
      'generated_at', now(),
      'timezone', app_timezone(),
      -- Counts first, so the person holding the file can check it against
      -- the app without reading the whole document.
      'counts', json_build_object(
        'stations',         (select count(*) from stations),
        'staff',            (select count(*) from staff),
        'tanks',            (select count(*) from tanks),
        'fuel_prices',      (select count(*) from fuel_prices),
        'sales',            (select count(*) from sales),
        'credit_customers', (select count(*) from credit_customers),
        'expenses',         (select count(*) from expenses),
        'shifts',           (select count(*) from shifts),
        'attendance',       (select count(*) from attendance),
        'deliveries',       (select count(*) from deliveries),
        'price_history',    (select count(*) from price_history),
        'sale_corrections', (select count(*) from sale_corrections)
      ),
      'stations',         coalesce((select json_agg(t) from stations t), '[]'::json),
      -- staff carries email and phone: business data the owner already sees
      -- in the app. password_hash is stripped by name rather than trusted to
      -- be absent. 0009 dropped that column, but a backup is exactly the
      -- wrong place to depend on a migration having run - if the column ever
      -- exists again, on any database this is pointed at, the file must not
      -- carry it out of the building.
      'staff',            coalesce((select jsonb_agg(to_jsonb(t) - 'password_hash')
                                      from staff t), '[]'::jsonb),
      'tanks',            coalesce((select json_agg(t) from tanks t), '[]'::json),
      'fuel_prices',      coalesce((select json_agg(t) from fuel_prices t), '[]'::json),
      'sales',            coalesce((select json_agg(t) from sales t), '[]'::json),
      'credit_customers', coalesce((select json_agg(t) from credit_customers t), '[]'::json),
      'expenses',         coalesce((select json_agg(t) from expenses t), '[]'::json),
      'shifts',           coalesce((select json_agg(t) from shifts t), '[]'::json),
      'attendance',       coalesce((select json_agg(t) from attendance t), '[]'::json),
      'deliveries',       coalesce((select json_agg(t) from deliveries t), '[]'::json),
      'price_history',    coalesce((select json_agg(t) from price_history t), '[]'::json),
      'sale_corrections', coalesce((select json_agg(t) from sale_corrections t), '[]'::json)
    )
  end;
$$;

grant execute on function admin_backup() to authenticated;



notify pgrst, 'reload schema';


