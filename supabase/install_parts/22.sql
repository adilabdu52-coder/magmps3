-- MAGPMS install 22 of 23 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Corrections, part 2: what the admin sees, and fixing or rejecting.
set search_path = public, extensions;
-- ---------------------------------------------------------------
-- what the admin sees
-- ---------------------------------------------------------------
create or replace function admin_list_corrections(
  p_station_id uuid default null, p_status text default 'open', p_limit int default 100)
returns table (id uuid, sale_id uuid, station_id uuid, station_name text,
               staff_name text, reported_at timestamptz, reason text,
               claimed_liters numeric, status text, fuel_type text,
               sale_liters numeric, sale_total numeric, payment_method text,
               sale_at timestamptz, resolved_at timestamptz, resolution_note text,
               old_liters numeric, new_liters numeric)
language sql stable security definer set search_path = public
as $$
  select c.id, c.sale_id, c.station_id, st.name, rep.full_name,
         c.reported_at, c.reason, c.claimed_liters, c.status,
         s.fuel_type, s.liters, s.total_etb, s.payment_method, s.created_at,
         c.resolved_at, c.resolution_note, c.old_liters, c.new_liters
  from sale_corrections c
  join sales s        on s.id = c.sale_id
  left join stations st on st.id = c.station_id
  left join staff rep   on rep.id = c.reported_by
  where is_admin()
    and (p_station_id is null or c.station_id = p_station_id)
    and (p_status is null or p_status = 'all' or c.status = p_status)
  order by c.reported_at desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

-- ---------------------------------------------------------------
-- the admin decides
-- ---------------------------------------------------------------
-- Fixing re-prices at the sale's OWN unit rate, not today's. A sale made
-- yesterday at 95 stays at 95 even if the price moved this morning -
-- correcting a typo must not quietly restate history at a different price.
create or replace function admin_resolve_correction(
  p_correction_id uuid, p_action text,
  p_correct_liters numeric default null, p_note text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_admin  staff := current_staff();
  c        sale_corrections;
  s        sales;
  v_liters numeric;
  v_unit   numeric;
  v_total  numeric;
  v_delta  numeric;
  v_tank   int;
  v_stock  numeric;
begin
  if not is_admin() then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if p_action not in ('fix', 'reject') then
    return json_build_object('success', false, 'message', 'unknown action');
  end if;

  select * into c from sale_corrections where id = p_correction_id;
  if c.id is null then
    return json_build_object('success', false, 'message', 'no such report');
  end if;
  if c.status <> 'open' then
    return json_build_object('success', false, 'message', 'already dealt with');
  end if;

  if p_action = 'reject' then
    update sale_corrections
       set status = 'rejected', resolved_by = v_admin.id,
           resolved_at = now(), resolution_note = nullif(trim(p_note), '')
     where id = p_correction_id;
    return json_build_object('success', true, 'message', 'report rejected');
  end if;

  -- ---- fix ----
  v_liters := coalesce(p_correct_liters, c.claimed_liters);
  if v_liters is null or v_liters <= 0 then
    return json_build_object('success', false, 'message', 'enter the correct litres');
  end if;

  select * into s from sales where id = c.sale_id;
  if s.id is null then
    return json_build_object('success', false, 'message', 'sale not found');
  end if;
  if coalesce(s.voided, false) then
    return json_build_object('success', false, 'message', 'that sale has been voided since');
  end if;
  if coalesce(s.liters, 0) <= 0 then
    return json_build_object('success', false, 'message', 'the original sale has no litres to re-price from');
  end if;

  v_unit  := s.total_etb / s.liters;
  v_total := round(v_liters * v_unit, 2);
  v_delta := v_liters - s.liters;          -- positive means MORE fuel left the tank

  -- The tank moves by the difference only. The original sale already took
  -- its litres out; this corrects that movement rather than repeating it.
  --
  -- Which tank depends on the direction, the same way voiding does: take the
  -- extra from the fullest, and put a refund back into the emptiest. Picking
  -- one tank for both would drain a nearly-empty tank, or overfill a full
  -- one, for no reason other than that it happened to sort first.
  if v_delta > 0 then
    select id, current_liters into v_tank, v_stock from tanks
     where station_id = s.station_id and fuel_type = s.fuel_type
     order by current_liters desc limit 1;

    if v_tank is not null and v_stock < v_delta then
      -- Refuse rather than write a negative tank. A tank that cannot have
      -- held the fuel means the corrected figure is wrong, or the stock is.
      return json_build_object('success', false,
        'message', 'the tank does not hold enough for that correction - check the figure');
    end if;
  else
    select id, current_liters into v_tank, v_stock from tanks
     where station_id = s.station_id and fuel_type = s.fuel_type
     order by current_liters asc limit 1;

    if v_tank is not null
       and (select current_liters - v_delta > capacity_liters from tanks where id = v_tank) then
      return json_build_object('success', false,
        'message', 'putting that much back would overfill the tank - check the figure');
    end if;
  end if;

  update sales set liters = v_liters, total_etb = v_total where id = s.id;

  if v_tank is not null then
    update tanks set current_liters = current_liters - v_delta where id = v_tank;
  end if;

  -- Credit follows the money, in the same direction.
  if s.payment_method = 'credit' and s.credit_customer_id is not null then
    update credit_customers
       set balance = greatest(0, balance + (v_total - s.total_etb))
     where id = s.credit_customer_id;
  end if;

  update sale_corrections
     set status = 'fixed', resolved_by = v_admin.id, resolved_at = now(),
         resolution_note = nullif(trim(p_note), ''),
         old_liters = s.liters, old_total = s.total_etb,
         new_liters = v_liters, new_total = v_total
   where id = p_correction_id;

  return json_build_object('success', true, 'message', 'sale corrected');
end; $$;

grant execute on function report_sale_mistake(uuid, text, numeric)          to authenticated;
grant execute on function my_corrections(int)                               to authenticated;
grant execute on function admin_list_corrections(uuid, text, int)           to authenticated;
grant execute on function admin_resolve_correction(uuid, text, numeric, text) to authenticated;



notify pgrst, 'reload schema';



