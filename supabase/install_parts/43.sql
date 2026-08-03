-- MAGPMS install 43 of 44 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Reset, part 2: the deletion itself. Refuses without the word RESET.
-- p_restore true puts the fuel back into the tanks and the credit back off
-- the accounts; false deletes the rows and touches nothing else, for when
-- you are going to dip the tanks and enter the real levels yourself.
--
-- A VOIDED SALE IS ALREADY REVERSED - admin_void_sale put its fuel back at
-- the void - so voided rows are deleted without being reversed again.
set search_path = public, extensions;

create or replace function admin_reset_transactions(
  p_from date, p_to date,
  p_station_id uuid default null,
  p_confirm text default null,
  p_restore boolean default true)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_admin staff := current_staff();
  r record;
  v_tank int;
  v_sales int := 0; v_shifts int := 0; v_att int := 0;
  v_exp int := 0; v_deliv int := 0; v_corr int := 0;
  v_litres numeric := 0; v_credit numeric := 0;
  v_no_tank jsonb := '[]'::jsonb;
  v_over jsonb := '[]'::jsonb;
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
  if coalesce(p_confirm, '') <> 'RESET' then
    return json_build_object('success', false,
      'message', 'type RESET to confirm - nothing has been deleted');
  end if;
  for r in
    select s.station_id, s.fuel_type, sum(s.liters) as liters
      from sales s
     where coalesce(p_restore, true)
       and (p_station_id is null or s.station_id = p_station_id)
       and not coalesce(s.voided, false)
       and (s.created_at at time zone app_timezone())::date between p_from and p_to
     group by 1, 2
  loop
    select id into v_tank from tanks
     where station_id = r.station_id and fuel_type = r.fuel_type
     order by current_liters asc limit 1;
    if v_tank is null then
      v_no_tank := v_no_tank || jsonb_build_object(
        'branch', (select name from stations where id = r.station_id),
        'fuel', r.fuel_type, 'liters', r.liters);
    else
      update tanks set current_liters = current_liters + r.liters where id = v_tank;
      v_litres := v_litres + r.liters;
      if (select current_liters > capacity_liters from tanks where id = v_tank) then
        v_over := v_over || jsonb_build_object(
          'tank', (select tank_name from tanks where id = v_tank),
          'branch', (select name from stations where id = r.station_id),
          'liters', (select current_liters from tanks where id = v_tank),
          'capacity', (select capacity_liters from tanks where id = v_tank));
      end if;
    end if;
  end loop;
  for r in
    select s.credit_customer_id as cid, sum(s.total_etb) as etb
      from sales s
     where coalesce(p_restore, true)
       and (p_station_id is null or s.station_id = p_station_id)
       and not coalesce(s.voided, false)
       and s.payment_method = 'credit' and s.credit_customer_id is not null
       and (s.created_at at time zone app_timezone())::date between p_from and p_to
     group by 1
  loop
    update credit_customers set balance = greatest(0, balance - r.etb) where id = r.cid;
    v_credit := v_credit + r.etb;
  end loop;
  with gone as (
    delete from sale_corrections c
     where exists (select 1 from sales s where s.id = c.sale_id
       and (p_station_id is null or s.station_id = p_station_id)
       and (s.created_at at time zone app_timezone())::date between p_from and p_to)
    returning 1)
  select count(*) into v_corr from gone;
  with gone as (
    delete from sales s
     where (p_station_id is null or s.station_id = p_station_id)
       and (s.created_at at time zone app_timezone())::date between p_from and p_to
    returning 1)
  select count(*) into v_sales from gone;
  for r in
    select d.tank_id, sum(d.liters) as liters
      from deliveries d
     where coalesce(p_restore, true)
       and (p_station_id is null or d.station_id = p_station_id)
       and d.tank_id is not null
       and (d.created_at at time zone app_timezone())::date between p_from and p_to
     group by 1
  loop
    update tanks set current_liters = greatest(0, current_liters - r.liters)
     where id = r.tank_id;
  end loop;
  with gone as (
    delete from deliveries d
     where (p_station_id is null or d.station_id = p_station_id)
       and (d.created_at at time zone app_timezone())::date between p_from and p_to
    returning 1)
  select count(*) into v_deliv from gone;
  with gone as (
    delete from shifts sh
     where (p_station_id is null or sh.station_id = p_station_id)
       and (sh.opened_at at time zone app_timezone())::date between p_from and p_to
    returning 1)
  select count(*) into v_shifts from gone;
  with gone as (
    delete from attendance a
     where (p_station_id is null or a.station_id = p_station_id)
       and (a.check_in at time zone app_timezone())::date between p_from and p_to
    returning 1)
  select count(*) into v_att from gone;
  with gone as (
    delete from expenses e
     where (p_station_id is null or e.station_id = p_station_id)
       and (e.created_at at time zone app_timezone())::date between p_from and p_to
    returning 1)
  select count(*) into v_exp from gone;
  insert into branch_notes (station_id, body, pinned, created_by)
  values (p_station_id,
          format('Data reset: %s sales, %s shifts, %s attendance, %s expenses, %s deliveries '
                 || 'removed for %s to %s. %s L returned to tanks, %s ETB taken off credit.',
                 v_sales, v_shifts, v_att, v_exp, v_deliv, p_from, p_to,
                 round(v_litres, 2), round(v_credit, 2)),
          false, v_admin.id);
  return json_build_object(
    'success', true,
    'message', format('%s sales removed, %s L returned to the tanks', v_sales, round(v_litres, 2)),
    'from', p_from, 'to', p_to,
    'sales', v_sales, 'shifts', v_shifts, 'attendance', v_att,
    'expenses', v_exp, 'deliveries', v_deliv, 'corrections', v_corr,
    'liters_returned', round(v_litres, 2),
    'credit_cleared', round(v_credit, 2),
    'no_tank_for', v_no_tank,
    'over_capacity', v_over);
end; $$;

grant execute on function admin_reset_transactions(date, date, uuid, text, boolean)
  to authenticated;

notify pgrst, 'reload schema';
