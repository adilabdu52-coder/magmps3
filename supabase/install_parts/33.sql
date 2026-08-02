-- MAGPMS install 33 of 39 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- And the shifts list says which shifts were closed by somebody other than
-- the person who worked them.
set search_path = public, extensions;
-- ---------------------------------------------------------------
-- and say so in the list
-- ---------------------------------------------------------------
drop function if exists list_shifts(uuid, int, int);

create or replace function list_shifts(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text, nozzle_label text,
  opened_at timestamptz, closed_at timestamptz,
  opening_meter numeric, closing_meter numeric,
  metered_liters numeric, sold_liters numeric, variance_liters numeric,
  abandoned boolean, closed_by_other boolean)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.station_id, coalesce(st.name, '(no branch)'), stf.full_name,
         coalesce(n.label, '-'),
         sh.opened_at, sh.closed_at, sh.opening_meter, sh.closing_meter,
         case when sh.closing_meter is null then null
              else sh.closing_meter - sh.opening_meter end,
         coalesce(sold.liters, 0),
         case when sh.closing_meter is null then null
              else (sh.closing_meter - sh.opening_meter) - coalesce(sold.liters, 0) end,
         sh.abandoned,
         -- A variance from a meter the operator never read is worth less than
         -- one they did. The column says which, rather than leaving both
         -- looking the same a week later.
         (sh.closed_by is not null and sh.closed_by <> sh.staff_id)
    from shifts sh
    left join stations st on st.id = sh.station_id
    left join staff stf on stf.id = sh.staff_id
    left join nozzles n on n.id = sh.nozzle_id
    left join lateral (
      select sum(s.liters) as liters
        from sales s
       where s.nozzle_id is not distinct from sh.nozzle_id
         and s.staff_id = sh.staff_id
         and not coalesce(s.voided, false)
         and s.created_at >= sh.opened_at
         and s.created_at <  coalesce(sh.closed_at, now())
    ) sold on true
   where (case when is_admin()
               then (p_station_id is null or sh.station_id = p_station_id)
               else sh.station_id = current_station() end)
     and sh.opened_at >= now() - make_interval(days => greatest(1, p_days))
   order by sh.opened_at desc
   limit greatest(1, least(p_limit, 500));
$$;

grant execute on function close_shift(uuid, numeric)  to authenticated;
grant execute on function list_shifts(uuid, int, int) to authenticated;



notify pgrst, 'reload schema';


