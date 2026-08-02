-- MAGPMS install 31 of 39 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Nozzles, part 5: the variance, now scoped to the pump rather than the
-- person - which is what makes it mean anything.
set search_path = public, extensions;
-- ---------------------------------------------------------------
-- what the admin sees
-- ---------------------------------------------------------------
-- sold_liters is now scoped to the NOZZLE, not the person. With two shifts
-- open at once, scoping by person would credit every sale to both of them and
-- make both variances wrong.
drop function if exists list_shifts(uuid, int, int);

create or replace function list_shifts(
  p_station_id uuid default null, p_days int default 7, p_limit int default 200)
returns table (
  id uuid, station_id uuid, station_name text, staff_name text, nozzle_label text,
  opened_at timestamptz, closed_at timestamptz,
  opening_meter numeric, closing_meter numeric,
  metered_liters numeric, sold_liters numeric, variance_liters numeric,
  abandoned boolean)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.station_id, coalesce(st.name, '(no branch)'), stf.full_name,
         coalesce(n.label, '—'),
         sh.opened_at, sh.closed_at, sh.opening_meter, sh.closing_meter,
         case when sh.closing_meter is null then null
              else sh.closing_meter - sh.opening_meter end,
         coalesce(sold.liters, 0),
         case when sh.closing_meter is null then null
              else (sh.closing_meter - sh.opening_meter) - coalesce(sold.liters, 0) end,
         sh.abandoned
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

create or replace function admin_set_nozzle(
  p_nozzle_id uuid, p_label text default null,
  p_fuel_type text default null, p_active boolean default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;

  update nozzles
     set label     = coalesce(nullif(trim(p_label), ''), label),
         fuel_type = coalesce(nullif(trim(p_fuel_type), ''), fuel_type),
         active    = coalesce(p_active, active)
   where id = p_nozzle_id;

  if not found then return json_build_object('success', false, 'message', 'no such nozzle'); end if;
  return json_build_object('success', true, 'message', 'nozzle updated');
end; $$;

grant execute on function list_nozzles(uuid)                        to authenticated;
grant execute on function open_shift(uuid, numeric)                 to authenticated;
grant execute on function close_shift(uuid, numeric)                to authenticated;
grant execute on function my_open_shifts()                          to authenticated;
grant execute on function record_sale(uuid, numeric, text, uuid)    to authenticated;
grant execute on function list_shifts(uuid, int, int)               to authenticated;
grant execute on function admin_set_nozzle(uuid, text, text, boolean) to authenticated;



notify pgrst, 'reload schema';


