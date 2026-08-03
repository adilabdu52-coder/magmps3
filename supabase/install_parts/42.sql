-- MAGPMS install 42 of 44 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Reset, part 1: reading what WOULD go, which changes nothing. A destructive
-- thing should be readable before it is done.
set search_path = public, extensions;

create or replace function admin_reset_preview(
  p_from date, p_to date, p_station_id uuid default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare v_out json;
begin
  if not is_admin() then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if p_from is null or p_to is null then
    return json_build_object('success', false, 'message', 'give both a From and a To date');
  end if;
  if p_from > p_to then
    return json_build_object('success', false, 'message', 'the From date is after the To date');
  end if;

  select json_build_object(
    'success', true,
    'from', p_from, 'to', p_to,
    'branch', coalesce((select name from stations where id = p_station_id), 'every branch'),

    'sales', (select count(*) from sales s
               where (p_station_id is null or s.station_id = p_station_id)
                 and (s.created_at at time zone app_timezone())::date between p_from and p_to),
    'voided_sales', (select count(*) from sales s
               where (p_station_id is null or s.station_id = p_station_id)
                 and coalesce(s.voided, false)
                 and (s.created_at at time zone app_timezone())::date between p_from and p_to),
    'shifts', (select count(*) from shifts sh
               where (p_station_id is null or sh.station_id = p_station_id)
                 and (sh.opened_at at time zone app_timezone())::date between p_from and p_to),
    'attendance', (select count(*) from attendance a
               where (p_station_id is null or a.station_id = p_station_id)
                 and (a.check_in at time zone app_timezone())::date between p_from and p_to),
    'expenses', (select count(*) from expenses e
               where (p_station_id is null or e.station_id = p_station_id)
                 and (e.created_at at time zone app_timezone())::date between p_from and p_to),
    'deliveries', (select count(*) from deliveries d
               where (p_station_id is null or d.station_id = p_station_id)
                 and (d.created_at at time zone app_timezone())::date between p_from and p_to),
    'corrections', (select count(*) from sale_corrections c
               where exists (select 1 from sales s where s.id = c.sale_id
                 and (p_station_id is null or s.station_id = p_station_id)
                 and (s.created_at at time zone app_timezone())::date between p_from and p_to)),

    -- Voided sales are left out: their litres went back at the void.
    'fuel_to_return', coalesce((
      select jsonb_agg(jsonb_build_object('branch', st.name, 'fuel', x.fuel_type,
                                          'liters', x.liters) order by st.name, x.fuel_type)
        from (select s.station_id, s.fuel_type, sum(s.liters) as liters
                from sales s
               where (p_station_id is null or s.station_id = p_station_id)
                 and not coalesce(s.voided, false)
                 and (s.created_at at time zone app_timezone())::date between p_from and p_to
               group by 1, 2) x
        join stations st on st.id = x.station_id), '[]'::jsonb),

    'credit_to_clear', coalesce((
      select jsonb_agg(jsonb_build_object('customer', cc.name, 'etb', x.etb) order by cc.name)
        from (select s.credit_customer_id as cid, sum(s.total_etb) as etb
                from sales s
               where (p_station_id is null or s.station_id = p_station_id)
                 and not coalesce(s.voided, false)
                 and s.payment_method = 'credit' and s.credit_customer_id is not null
                 and (s.created_at at time zone app_timezone())::date between p_from and p_to
               group by 1) x
        join credit_customers cc on cc.id = x.cid), '[]'::jsonb),

    'message', 'nothing has been deleted - this is only a preview'
  ) into v_out;

  return v_out;
end; $$;

grant execute on function admin_reset_preview(date, date, uuid) to authenticated;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select admin_reset_preview('2026-08-01', '2026-08-03');
--
-- Counts only. Nothing is deleted by this.
