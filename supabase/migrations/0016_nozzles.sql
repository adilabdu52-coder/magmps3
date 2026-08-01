-- 0016 — nozzles, and a shift that belongs to one
--
-- A shift carried one opening_meter and one closing_meter with no record of
-- WHICH meter. With ten nozzles at a branch that number cannot mean anything:
-- the variance column has been comparing a single reading against everything
-- the person sold, across every pump they touched. That is why it has not
-- been telling anybody anything.
--
-- A meter belongs to a nozzle, not to a person. So a shift now belongs to a
-- nozzle too: one open shift per nozzle, and a person working two pumps opens
-- two shifts. Variance then answers the question worth asking - which pump is
-- losing fuel - instead of an unanswerable one.
--
-- Sales carry the nozzle for the same reason. Without it, two open shifts by
-- the same person would each claim all of that person's sales, and the
-- variance would be wrong in both.
--
-- pumps, nozzles and nozzle_readings appear in 0002 and 0005 as "if this
-- table happens to exist" - inherited from the old app's schema and never
-- built here. This builds the one that earns its place.

begin;

-- ---------------------------------------------------------------
-- the nozzles
-- ---------------------------------------------------------------
create table if not exists nozzles (
  id         uuid primary key default gen_random_uuid(),
  station_id uuid not null references stations(id),
  label      text not null,
  fuel_type  text,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (station_id, label));

create index if not exists nozzles_station_idx on nozzles (station_id, active);

alter table nozzles enable row level security;
revoke all on nozzles from anon, authenticated;

-- Ten per branch, once. The fuel cycles through whatever that branch's tanks
-- actually hold, because a nozzle that dispenses a fuel the branch does not
-- stock is not a useful default. Rename or re-assign them in the app.
do $$
declare
  st record;
  fuels text[];
  i int;
begin
  for st in select id, name from stations loop
    if exists (select 1 from nozzles where station_id = st.id) then
      raise notice '% already has nozzles, leaving them alone', st.name;
      continue;
    end if;

    select coalesce(array_agg(distinct t.fuel_type order by t.fuel_type), array['Diesel'])
      into fuels
      from tanks t where t.station_id = st.id and t.fuel_type is not null;

    for i in 1..10 loop
      insert into nozzles (station_id, label, fuel_type)
      values (st.id, 'N' || i, fuels[1 + ((i - 1) % array_length(fuels, 1))]);
    end loop;
    raise notice '% : 10 nozzles created (%)', st.name, array_to_string(fuels, ', ');
  end loop;
end $$;

alter table shifts add column if not exists nozzle_id uuid references nozzles(id);
alter table sales  add column if not exists nozzle_id uuid references nozzles(id);

create index if not exists sales_nozzle_idx  on sales (nozzle_id, created_at);
create index if not exists shifts_nozzle_idx on shifts (nozzle_id) where closed_at is null;

-- One open shift per nozzle. Two people on the same pump at once would each
-- claim its meter movement, and neither figure would mean anything.
create unique index if not exists shifts_one_open_per_nozzle_idx
  on shifts (nozzle_id) where closed_at is null and not abandoned;

-- ---------------------------------------------------------------
-- reading them
-- ---------------------------------------------------------------
create or replace function list_nozzles(p_station_id uuid default null)
returns table (id uuid, station_id uuid, station_name text, label text,
               fuel_type text, active boolean,
               open_shift_id uuid, open_by text)
language sql stable security definer set search_path = public
as $$
  select n.id, n.station_id, st.name, n.label, n.fuel_type, n.active,
         sh.id, stf.full_name
    from nozzles n
    left join stations st on st.id = n.station_id
    left join lateral (
      select s.id, s.staff_id from shifts s
       where s.nozzle_id = n.id and s.closed_at is null and not s.abandoned
       order by s.opened_at desc limit 1
    ) sh on true
    left join staff stf on stf.id = sh.staff_id
   where (case when is_admin()
               then (p_station_id is null or n.station_id = p_station_id)
               else n.station_id = current_station() end)
   order by st.name, n.label;
$$;

-- ---------------------------------------------------------------
-- shifts, now against a nozzle
-- ---------------------------------------------------------------
drop function if exists open_shift(numeric);
drop function if exists close_shift(numeric);

create or replace function open_shift(p_nozzle_id uuid, p_opening_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  v_noz   nozzles;
  v_open  shifts;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if v_staff.station_id is null then
    return json_build_object('success', false,
      'message', 'no branch assigned - ask the manager before opening a shift');
  end if;
  if p_opening_meter is null or p_opening_meter < 0 then
    return json_build_object('success', false, 'message', 'enter the opening meter reading');
  end if;

  select * into v_noz from nozzles where id = p_nozzle_id;
  if v_noz.id is null then
    return json_build_object('success', false, 'message', 'choose a nozzle');
  end if;
  -- A nozzle at another branch is not theirs to open, whatever the app sent.
  if v_noz.station_id <> v_staff.station_id then
    return json_build_object('success', false, 'message', 'that nozzle is at another branch');
  end if;
  if not v_noz.active then
    return json_build_object('success', false, 'message', 'that nozzle is out of service');
  end if;

  -- Somebody else already on this pump.
  select * into v_open from shifts
   where nozzle_id = p_nozzle_id and closed_at is null and not abandoned
   order by opened_at desc limit 1;

  if v_open.id is not null then
    if (v_open.opened_at at time zone app_timezone())::date
       = (now() at time zone app_timezone())::date then
      return json_build_object('success', false,
        'message', case when v_open.staff_id = v_staff.id
                        then 'you already have this nozzle open'
                        else 'somebody else has this nozzle open' end);
    end if;
    -- Left open overnight: no closing meter was ever read, so no variance can
    -- exist for it. Mark it rather than invent one.
    update shifts set abandoned = true where id = v_open.id;
  end if;

  insert into shifts (station_id, staff_id, nozzle_id, opening_meter, opened_at)
  values (v_staff.station_id, v_staff.id, p_nozzle_id, p_opening_meter, now());

  return json_build_object('success', true, 'message', 'shift opened on ' || v_noz.label);
end; $$;

create or replace function close_shift(p_shift_id uuid, p_closing_meter numeric)
returns json language plpgsql security definer set search_path = public as $$
declare v_staff staff := current_staff(); sh shifts;
begin
  if v_staff.id is null then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if p_closing_meter is null or p_closing_meter < 0 then
    return json_build_object('success', false, 'message', 'enter the closing meter reading');
  end if;

  select * into sh from shifts where id = p_shift_id;
  if sh.id is null then return json_build_object('success', false, 'message', 'no such shift'); end if;
  if sh.staff_id <> v_staff.id then
    return json_build_object('success', false, 'message', 'that is not your shift');
  end if;
  if sh.closed_at is not null or sh.abandoned then
    return json_build_object('success', false, 'message', 'that shift is already closed');
  end if;

  -- A pump meter only counts up. A lower closing reading is a typo, and
  -- accepting it would show fuel appearing out of nowhere.
  if p_closing_meter < sh.opening_meter then
    return json_build_object('success', false,
      'message', 'the closing meter is below the opening one - check the reading');
  end if;

  update shifts set closing_meter = p_closing_meter, closed_at = now() where id = sh.id;
  return json_build_object('success', true, 'message', 'shift closed');
end; $$;

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

-- ---------------------------------------------------------------
-- selling, from a nozzle
-- ---------------------------------------------------------------
drop function if exists record_sale(text, numeric, text, uuid);

create or replace function record_sale(
  p_nozzle_id uuid, p_liters numeric, p_payment text,
  p_credit_customer_id uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_staff staff := current_staff();
  v_noz   nozzles;
  v_price numeric;
  v_tank  int;
  v_fuel  text;
begin
  if v_staff.id is null or v_staff.status <> 'approved' then
    return json_build_object('success', false, 'message', 'not authorised');
  end if;
  if v_staff.station_id is null then
    return json_build_object('success', false, 'message', 'no branch assigned');
  end if;
  if not (p_liters > 0) then
    return json_build_object('success', false, 'message', 'litres must be positive');
  end if;

  select * into v_noz from nozzles where id = p_nozzle_id;
  if v_noz.id is null or v_noz.station_id <> v_staff.station_id then
    return json_build_object('success', false, 'message', 'choose a nozzle at this branch');
  end if;

  -- The shift must be theirs AND on this nozzle. Selling from a pump you have
  -- not opened is how a meter reading stops matching what came out of it.
  if not exists (select 1 from shifts
                  where staff_id = v_staff.id and nozzle_id = p_nozzle_id
                    and closed_at is null and not abandoned) then
    return json_build_object('success', false, 'message', 'open a shift on this nozzle first');
  end if;

  -- The fuel is the nozzle's, not the seller's choice. A nozzle dispenses
  -- what it dispenses, and letting the till say otherwise is how stock and
  -- takings drift apart.
  v_fuel := v_noz.fuel_type;
  if v_fuel is null then
    return json_build_object('success', false, 'message', 'this nozzle has no fuel set - ask the manager');
  end if;

  select price_per_liter into v_price
    from fuel_prices where station_id = v_staff.station_id and fuel_type = v_fuel;
  if v_price is null then
    return json_build_object('success', false, 'message', 'no price set for ' || v_fuel);
  end if;

  if p_payment = 'credit' then
    if p_credit_customer_id is null then
      return json_build_object('success', false, 'message', 'choose a credit customer');
    end if;
    if not exists (select 1 from credit_customers
                    where id = p_credit_customer_id and station_id = v_staff.station_id) then
      return json_build_object('success', false, 'message', 'customer is not at this branch');
    end if;
  end if;

  select id into v_tank from tanks
   where station_id = v_staff.station_id and fuel_type = v_fuel
   order by current_liters desc limit 1;
  if v_tank is null then
    return json_build_object('success', false, 'message', 'no tank holds ' || v_fuel);
  end if;
  if (select current_liters from tanks where id = v_tank) < p_liters then
    return json_build_object('success', false, 'message', 'not enough stock in the tank');
  end if;

  insert into sales (station_id, staff_id, nozzle_id, fuel_type, liters, total_etb,
                     payment_method, credit_customer_id)
  values (v_staff.station_id, v_staff.id, p_nozzle_id, v_fuel, p_liters,
          round(p_liters * v_price, 2), p_payment, p_credit_customer_id);

  update tanks set current_liters = current_liters - p_liters where id = v_tank;

  if p_payment = 'credit' then
    update credit_customers set balance = balance + round(p_liters * v_price, 2)
     where id = p_credit_customer_id;
  end if;

  return json_build_object('success', true, 'message', 'sale recorded');
end; $$;

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

commit;

notify pgrst, 'reload schema';

-- ===============================================================
-- VERIFY
-- ===============================================================
--   select station_name, count(*) from list_nozzles(null)
--    group by station_name order by station_name;
--
-- Expect 10 for each of the five branches.
--
-- Sales recorded before this migration have no nozzle. Their shifts keep the
-- variance they always had, which was never meaningful; from here on it is.
--
--   select count(*) as sales_without_a_nozzle from sales where nozzle_id is null;
