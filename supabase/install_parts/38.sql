-- MAGPMS install 38 of 41 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Stale shifts, part 1: clear the shifts that were opened before pumps
-- existed and can never close, and keep them out of the till.
set search_path = public, extensions;

-- A shift with no nozzle has no meter, so no variance was ever obtainable
-- from it. Abandoned says exactly that. Inventing a closing reading would
-- put a made-up number into the one column that exists to find missing fuel.
update shifts
   set abandoned = true
 where closed_at is null
   and not abandoned
   and nozzle_id is null;

-- The sale box is built from this list, so a row with no nozzle here becomes
-- an option that cannot sell: the cashier reads "open a shift first" while
-- looking at a screen that says one is open.
create or replace function my_open_shifts()
returns table (id uuid, nozzle_id uuid, nozzle_label text, fuel_type text,
               opened_at timestamptz, opening_meter numeric, sold_liters numeric)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.nozzle_id, n.label, n.fuel_type, sh.opened_at, sh.opening_meter,
         coalesce((select sum(s.liters) from sales s
                    where s.nozzle_id = sh.nozzle_id
                      and not coalesce(s.voided, false)
                      and s.created_at >= sh.opened_at), 0)
    from shifts sh
    join nozzles n on n.id = sh.nozzle_id
   where sh.staff_id = (select id from current_staff())
     and sh.closed_at is null and not sh.abandoned
   order by sh.opened_at;
$$;

grant execute on function my_open_shifts() to authenticated;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select count(*) as still_stuck from shifts
--    where closed_at is null and not abandoned and nozzle_id is null;
--
-- Expect 0.
