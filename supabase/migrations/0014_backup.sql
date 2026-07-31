-- 0014 — a backup that is actually the whole thing
--
-- The obvious way to build an export is to call the listing functions the
-- pages already use and stitch the results together. That would be wrong, and
-- quietly so: every one of them caps at 500 rows, and list_shifts and
-- list_attendance also cap by days. Across five branches this business will
-- pass 500 sales in a week. The export would keep working, keep saying
-- "backup downloaded", and keep leaving rows out.
--
-- A backup that silently drops data is worse than no backup, because it is
-- believed. So this reads the tables directly, with no limit, and states how
-- many rows of each it found - a count you can compare against the app.
--
-- What this is for: Supabase's own backups are the real protection, and on
-- the free plan they are neither guaranteed nor easy to reach. This is the
-- copy that lives on your phone, or in your e-mail, and does not depend on
-- anyone's account still existing.

begin;

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

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
-- Signed in as an admin, the counts should match what the app shows:
--
--   select admin_backup() -> 'counts';
--
-- And as anyone else it must refuse rather than return a partial answer:
--
--   select admin_backup() ->> 'error';       -- expect: not authorised
--
-- ===============================================================
-- RESTORING
-- ===============================================================
-- This file is a record, not a restore button, and it is worth being honest
-- about the difference. Putting it back means inserting the rows again in
-- dependency order - stations, staff, tanks, then everything that references
-- them - and re-linking staff.auth_user_id to accounts that would have to be
-- recreated in Supabase Auth first, because auth.users is not in here and
-- cannot be.
--
-- What it is genuinely good for: proving what the books said on a given day,
-- moving to another project, and answering "what did we sell last March"
-- after something has gone wrong. Keep one a week, off the phone.
