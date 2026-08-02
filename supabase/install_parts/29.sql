-- MAGPMS install 29 of 39 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Nozzles, part 3: the list of pumps a person currently has open.
set search_path = public, extensions;
-- Plural: one person may be on two pumps at once, which is the whole point.
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
    left join nozzles n on n.id = sh.nozzle_id
   where sh.staff_id = (select id from current_staff())
     and sh.closed_at is null and not sh.abandoned
   order by sh.opened_at;
$$;


