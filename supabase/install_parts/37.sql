-- MAGPMS install 37 of 37 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Notes, part 4: reading those records back, with the fuels totalled
-- against what the meter moved.
set search_path = public, extensions;
-- ---------------------------------------------------------------
-- reading them back
-- ---------------------------------------------------------------
drop function if exists admin_list_notes(uuid, int);

create or replace function admin_list_notes(
  p_station_id uuid default null, p_limit int default 100)
returns table (id uuid, station_id uuid, station_name text, body text,
               pinned boolean, author text, created_at timestamptz,
               updated_at timestamptz,
               staff_name text, nozzle_label text,
               start_meter numeric, end_meter numeric, metered_liters numeric,
               fuel_liters jsonb, noted_liters numeric)
language sql stable security definer set search_path = public
as $$
  select n.id, n.station_id, coalesce(st.name, 'All branches'), n.body,
         n.pinned, stf.full_name, n.created_at, n.updated_at,
         who.full_name, noz.label,
         n.start_meter, n.end_meter,
         case when n.start_meter is null or n.end_meter is null then null
              else n.end_meter - n.start_meter end,
         n.fuel_liters,
         -- The fuels added up, so the manager can see at a glance whether
         -- what they wrote per fuel agrees with what the meter moved.
         (select sum((value)::text::numeric)
            from jsonb_each(coalesce(n.fuel_liters, '{}'::jsonb)))
    from branch_notes n
    left join stations st on st.id = n.station_id
    left join staff stf   on stf.id = n.created_by
    left join staff who   on who.id = n.staff_id
    left join nozzles noz on noz.id = n.nozzle_id
   where is_admin()
     and (p_station_id is null or n.station_id = p_station_id or n.station_id is null)
   order by n.pinned desc, n.created_at desc
   limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

grant execute on function admin_add_note(text, uuid, boolean, uuid, uuid, numeric, numeric, jsonb)
  to authenticated;
grant execute on function admin_list_notes(uuid, int) to authenticated;



notify pgrst, 'reload schema';


