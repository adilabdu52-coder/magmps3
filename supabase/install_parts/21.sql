-- MAGPMS install 21 of 44 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Corrections, part 1: the table, and the cashier reporting a wrong sale.
set search_path = public, extensions;
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


