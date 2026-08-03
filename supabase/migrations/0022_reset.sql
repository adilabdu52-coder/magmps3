-- 0022 — clearing the testing out, without leaving the tanks crooked
--
-- Three days of trying the app out put 42,675 litres through the tills at
-- Hirna and Adama in seventeen sales, averaging over three thousand litres
-- each. Those are not forecourt sales. Before real trading starts they want
-- to be gone.
--
-- The obvious way to do that is wrong. `delete from sales` removes the rows
-- and NOTHING ELSE: the fuel those sales took out of the tanks stays out, and
-- the credit they put on a customer's account stays on it. The tank then
-- reads tens of thousands of litres below what is in the ground for ever,
-- and every pump variance measured against it is wrong from that day on.
-- That is a worse state than the test data was.
--
-- So a reset has to reverse the effects as well as remove the rows:
--
--   sales        litres back into the tank, credit off the account
--   deliveries   litres back OUT of the tank they were added to
--   shifts, attendance, expenses, corrections   rows only, no side effects
--
-- WHAT IT WILL NOT TOUCH: branches, staff, pumps, prices, price history,
-- credit customers, tanks themselves, or notes. Those are the setup, not the
-- trading, and losing them would mean building the whole thing again.
--
-- A VOIDED SALE IS ALREADY REVERSED. admin_void_sale puts the fuel back and
-- takes the money off the account at the moment of voiding. Adding its litres
-- back a second time here would invent fuel out of nothing - so voided sales
-- are deleted with the rest but their effects are deliberately NOT reversed.
-- This is exactly the sort of thing that goes wrong when it is done by hand.
--
-- CREDIT IS APPROXIMATE, AND HONESTLY SO. Payments are not recorded anywhere:
-- admin_credit_payment decrements the balance and keeps no row. A balance
-- therefore cannot be recomputed from history - the best available reversal
-- is to subtract the credit sales being deleted, floored at zero. Where a
-- customer has since paid, that floor is doing real work.
--
-- Two functions, because a destructive thing should be readable before it
-- is done: admin_reset_preview says what WOULD go, and changes nothing.

begin;

-- ---------------------------------------------------------------
-- look first
-- ---------------------------------------------------------------
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

-- ---------------------------------------------------------------
-- then do it
-- ---------------------------------------------------------------
-- p_restore: put the fuel back into the tanks and the credit back off the
-- accounts as the rows go. TRUE is the right default - it is the arithmetic
-- nobody does by hand, and skipping it silently is how a tank ends up reading
-- short for ever.
--
-- FALSE is the honest option for one case, and it is the case in front of us:
-- when the manager is going to walk out and dip the tanks anyway. Then the
-- restored figure is overwritten within the minute and putting it there first
-- only risks a spurious over-capacity warning. Pair it with
-- admin_set_tank_level below - do not leave the tanks on a number nobody has
-- checked.
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

  -- A word typed on purpose. Everything this function does is permanent and
  -- there is no undo but the backup file, so it must not be possible to
  -- reach by mistyping a date or clicking the wrong button.
  if coalesce(p_confirm, '') <> 'RESET' then
    return json_build_object('success', false,
      'message', 'type RESET to confirm - nothing has been deleted');
  end if;

  -- 1. fuel back into the tanks, from the LIVE sales only
  -- The emptiest tank of that fuel, which is where voiding puts it back too.
  -- Using the same tank for both keeps one branch's stock from drifting into
  -- one tank across many corrections.
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
      -- Nowhere to put it back. Say so rather than dropping it silently:
      -- those litres are unaccounted for and somebody has to know.
      v_no_tank := v_no_tank || jsonb_build_object(
        'branch', (select name from stations where id = r.station_id),
        'fuel', r.fuel_type, 'liters', r.liters);
    else
      update tanks set current_liters = current_liters + r.liters where id = v_tank;
      v_litres := v_litres + r.liters;

      -- Not clamped to capacity. A tank reading above what it can hold is
      -- visibly wrong and gets fixed; a number quietly trimmed to fit looks
      -- right and stays wrong.
      if (select current_liters > capacity_liters from tanks where id = v_tank) then
        v_over := v_over || jsonb_build_object(
          'tank', (select tank_name from tanks where id = v_tank),
          'branch', (select name from stations where id = r.station_id),
          'liters', (select current_liters from tanks where id = v_tank),
          'capacity', (select capacity_liters from tanks where id = v_tank));
      end if;
    end if;
  end loop;

  -- 2. credit off the accounts, live sales only
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

  -- 3. the rows. Corrections first: they point at the sales.
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

  -- 4. deliveries put fuel IN, so removing one takes it back out again.
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

  -- 5. rows with no side effects
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

  -- 6. write down that it happened.
  -- In a year somebody will ask why the figures start where they do, and a
  -- note in the manager's own notebook is a better answer than silence.
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
    -- Both of these mean somebody has to go and look at something.
    'no_tank_for', v_no_tank,
    'over_capacity', v_over);
end; $$;

-- ---------------------------------------------------------------
-- and a way to say what is actually in the tank
-- ---------------------------------------------------------------
-- Every other tank write in this database is a + or a -: a sale takes fuel
-- out, a delivery puts it in, a void or a correction moves it back. There has
-- never been a way to say "I have dipped this tank and it holds 12,400
-- litres" - which is the one number that is not a calculation but a
-- measurement, and the only one that can settle an argument with the
-- arithmetic.
--
-- Without this, a manager whose tank reads wrong has to record a delivery
-- that never arrived to bring it back up. That fixes the number and puts a
-- lie in the delivery history, where it will be read next year as a real
-- tanker that came.
create or replace function admin_set_tank_level(
  p_tank_id int, p_liters numeric, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_admin staff := current_staff();
  t tanks;
  v_station text;
begin
  if not is_admin() then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;

  select * into t from tanks where id = p_tank_id;
  if t.id is null then return json_build_object('success', false, 'message', 'no such tank'); end if;

  if p_liters is null or p_liters < 0 then
    return json_build_object('success', false, 'message', 'enter the litres in the tank');
  end if;
  -- A stick cannot read more than the tank holds, so this is a typo. Letting
  -- it through would make every stock percentage on the dashboard nonsense.
  if t.capacity_liters is not null and p_liters > t.capacity_liters then
    return json_build_object('success', false,
      'message', format('that is more than the tank holds (%s L) - check the figure',
                        round(t.capacity_liters)));
  end if;

  update tanks set current_liters = p_liters where id = p_tank_id;

  -- Written down, because a stock figure that changed by hand and left no
  -- trace is indistinguishable from one that drifted.
  select name into v_station from stations where id = t.station_id;
  insert into branch_notes (station_id, body, pinned, created_by)
  values (t.station_id,
          format('Tank level set by hand: %s %s from %s L to %s L.%s',
                 coalesce(v_station, ''), coalesce(t.tank_name, ''),
                 round(coalesce(t.current_liters, 0)), round(p_liters),
                 case when coalesce(trim(p_note), '') = '' then ''
                      else ' ' || trim(p_note) end),
          false, v_admin.id);

  return json_build_object('success', true,
    'message', format('%s set to %s L', coalesce(t.tank_name, 'tank'), round(p_liters)),
    'was', round(coalesce(t.current_liters, 0)), 'now', round(p_liters));
end; $$;

grant execute on function admin_reset_preview(date, date, uuid)             to authenticated;
grant execute on function admin_reset_transactions(date, date, uuid, text, boolean)
  to authenticated;
grant execute on function admin_set_tank_level(int, numeric, text)          to authenticated;

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
-- TAKE A BACKUP FIRST. Admin - Backup - download. It is the only way back.
--
-- 1. Read what would go, which changes nothing:
--
--      select admin_reset_preview('2026-08-01', '2026-08-03');
--
-- 2. If that is right, do it. The last argument is p_restore - pass FALSE
--    when you are going to dip the tanks and type the real levels in, which
--    is the usual case after clearing out testing:
--
--      select admin_reset_transactions('2026-08-01', '2026-08-03', null, 'RESET', false);
--
--    Pass TRUE (or leave it off) to have the fuel put back into the tanks and
--    the credit taken off the accounts as the rows go.
--
-- 3. Then dip the tanks and say what is in them. Find the ids first:
--
--      select t.id, st.name, t.tank_name, t.fuel_type,
--             t.current_liters, t.capacity_liters
--        from tanks t join stations st on st.id = t.station_id
--       order by st.name, t.tank_name;
--
--      select admin_set_tank_level(1, 12400, 'dipped after the reset');
--
--    Only the stick knows what is really in the ground. Every other figure
--    in this database is arithmetic on top of it.
