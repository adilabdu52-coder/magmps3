-- 0012 — corrections: a cashier reports a wrong sale, an admin decides
--
-- A cashier cannot change a sale once it is saved, and that is right: a till
-- you can edit is a till you cannot trust. But the consequence, until now,
-- was that a mistyped sale had nowhere to go. Someone who rings up 1000
-- litres instead of 100 knows within seconds and can do nothing except tell
-- their manager verbally and hope. The books stay wrong, the tank reads wrong,
-- and it surfaces a week later as a variance nobody can explain.
--
-- So: the cashier reports it, the admin decides. Fixing re-adjusts the tank
-- and the customer's credit balance so the dashboard and the reports become
-- correct again, and the whole exchange is kept as a record - who reported
-- what, who decided, when, and what the numbers were before and after.
--
-- Voiding a sale already existed and stays. The difference is who can start
-- it: voiding is something the admin does to a sale they happen to notice,
-- while a correction begins with the person who made the mistake.

begin;

-- ---------------------------------------------------------------
-- the record
-- ---------------------------------------------------------------
-- old_liters and old_total are filled in at the moment of fixing, not at the
-- moment of reporting. The sale can be corrected only once, but a report
-- might sit for a day before anyone looks at it, and what matters for the
-- audit trail is what the numbers actually were when they changed.
create table if not exists sale_corrections (
  id             uuid primary key default gen_random_uuid(),
  sale_id        uuid not null references sales(id),
  station_id     uuid references stations(id),
  reported_by    uuid references staff(id),
  reported_at    timestamptz not null default now(),
  reason         text,
  claimed_liters numeric,
  status         text not null default 'open',
  resolved_by    uuid references staff(id),
  resolved_at    timestamptz,
  resolution_note text,
  old_liters     numeric,
  old_total      numeric,
  new_liters     numeric,
  new_total      numeric);

create index if not exists sale_corrections_status_idx
  on sale_corrections (status, reported_at desc);
create index if not exists sale_corrections_station_idx
  on sale_corrections (station_id, reported_at desc);

-- One open report per sale. Without this, a cashier tapping twice creates two
-- reports, an admin fixes both, and the tank is adjusted for the same mistake
-- a second time - which is a worse error than the one being corrected.
create unique index if not exists sale_corrections_one_open_idx
  on sale_corrections (sale_id) where status = 'open';

alter table sale_corrections enable row level security;
revoke all on sale_corrections from anon, authenticated;

-- ---------------------------------------------------------------
-- the cashier reports it
-- ---------------------------------------------------------------
create or replace function report_sale_mistake(
  p_sale_id uuid, p_reason text, p_correct_liters numeric default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  s sales;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if coalesce(trim(p_reason), '') = '' then
    return json_build_object('success', false, 'message', 'say what went wrong');
  end if;

  select * into s from sales where id = p_sale_id;
  if s.id is null then
    return json_build_object('success', false, 'message', 'sale not found');
  end if;

  -- Own sales only. Not a matter of trust: a cashier reporting somebody
  -- else's sale is describing something they did not see.
  if s.staff_id is distinct from v_staff.id then
    return json_build_object('success', false, 'message', 'that is not your sale');
  end if;
  if coalesce(s.voided, false) then
    return json_build_object('success', false, 'message', 'that sale was already voided');
  end if;
  if exists (select 1 from sale_corrections
              where sale_id = p_sale_id and status = 'open') then
    return json_build_object('success', false, 'message', 'already reported - the manager has it');
  end if;
  if p_correct_liters is not null and p_correct_liters <= 0 then
    return json_build_object('success', false, 'message', 'litres must be more than zero');
  end if;

  insert into sale_corrections (sale_id, station_id, reported_by, reason, claimed_liters)
  values (p_sale_id, s.station_id, v_staff.id, trim(p_reason), p_correct_liters);

  return json_build_object('success', true, 'message', 'reported - the manager will review it');
end; $$;

-- ---------------------------------------------------------------
-- what the cashier can see afterwards
-- ---------------------------------------------------------------
-- Being able to see that it was received, and what was decided, is most of
-- the point. A report that vanishes is no better than telling someone.
create or replace function my_corrections(p_limit int default 20)
returns table (id uuid, sale_id uuid, reported_at timestamptz, reason text,
               claimed_liters numeric, status text, resolved_at timestamptz,
               resolution_note text, fuel_type text, old_liters numeric,
               new_liters numeric)
language sql stable security definer set search_path = public
as $$
  select c.id, c.sale_id, c.reported_at, c.reason, c.claimed_liters, c.status,
         c.resolved_at, c.resolution_note, s.fuel_type, c.old_liters, c.new_liters
  from sale_corrections c
  join sales s on s.id = c.sale_id
  where c.reported_by = (select id from current_staff())
  order by c.reported_at desc
  limit greatest(1, least(coalesce(p_limit, 20), 200));
$$;

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

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
-- 1. The table and its guard exist:
--
--      select indexname from pg_indexes
--       where tablename = 'sale_corrections';
--
--    Expect sale_corrections_one_open_idx among them - that is what stops
--    the same mistake being corrected twice.
--
-- 2. A cashier can report only their own sale. Signed in as one:
--
--      select report_sale_mistake('<someone-elses-sale>', 'wrong amount');
--
--    Expect {"success": false, "message": "that is not your sale"}.
--
-- 3. After fixing one, the numbers agree. The sale, the tank and the report
--    should tell the same story:
--
--      select old_liters, new_liters, old_total, new_total, status
--        from sale_corrections order by reported_at desc limit 1;
