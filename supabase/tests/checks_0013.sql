-- Checks for 0013: report_staff must agree with the sales it is built from.
--
--   psql -f supabase/tests/fixture.sql -f supabase/tests/auth_meta.sql \
--        -f supabase/migrations/0008_local_day.sql \
--        -f supabase/migrations/0013_staff_report.sql \
--        -f supabase/tests/checks_0013.sql

do $$
declare
  v_admin_auth uuid := gen_random_uuid();
  v_a_auth uuid := gen_random_uuid();
  v_b_auth uuid := gen_random_uuid();
  v_a uuid; v_b uuid; v_s1 uuid; v_s2 uuid;
  r record;
  v_n numeric; v_m numeric;
  -- Bounds in the APP's timezone, not the server's. At 21:30 UTC it is
  -- already tomorrow in Addis, so current_date here would exclude sales the
  -- app quite correctly counts as today.
  v_to date; v_from date;
begin
  insert into auth.users (id, email) values
    (v_admin_auth,'admin@x.com'), (v_a_auth,'a@x.com'), (v_b_auth,'b@x.com');
  insert into stations (name, town) values ('Adama','East Shewa') returning id into v_s1;
  insert into stations (name, town) values ('Hirna','West Hararghe') returning id into v_s2;

  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_admin_auth,'Owner','admin','approved',null);
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_a_auth,'Abebe','operator','approved',v_s1) returning id into v_a;
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_b_auth,'Chaltu','operator','approved',v_s2) returning id into v_b;

  -- Abebe: two cash sales today, one credit, one voided.
  insert into sales (station_id, staff_id, fuel_type, liters, total_etb, payment_method, voided, created_at)
  values
    (v_s1, v_a, 'Diesel', 100, 9500, 'cash',   false, now()),
    (v_s1, v_a, 'Diesel',  50, 4750, 'cash',   false, now()),
    (v_s1, v_a, 'Benzil',  20, 1800, 'credit', false, now()),
    (v_s1, v_a, 'Diesel', 999, 94905,'cash',   true,  now());

  -- Yesterday, so days_active is two and the best day is today.
  insert into sales (station_id, staff_id, fuel_type, liters, total_etb, payment_method, created_at)
  values (v_s1, v_a, 'Diesel', 10, 950, 'cash', now() - interval '1 day');

  -- Chaltu, at the other branch.
  insert into sales (station_id, staff_id, fuel_type, liters, total_etb, payment_method, created_at)
  values (v_s2, v_b, 'Diesel', 30, 2850, 'cash', now());

  v_to   := (now() at time zone app_timezone())::date;
  v_from := v_to - 7;

  perform set_config('test.uid', v_admin_auth::text, false);

  -- ---------------------------------------------------------------
  -- 1. one row per person, and the money is right
  -- ---------------------------------------------------------------
  select * into r from report_staff(null, v_from, v_to)
   where staff_name = 'Abebe';

  if r.staff_name is null then raise exception 'Abebe is missing from the report'; end if;
  -- 9500 + 4750 + 1800 + 950 = 17 000. The voided 94 905 is not in it.
  if r.sales_etb <> 17000 then raise exception 'sales_etb is % not 17000', r.sales_etb; end if;
  if r.sale_count <> 4    then raise exception 'sale_count is % not 4', r.sale_count; end if;
  if r.liters <> 180      then raise exception 'liters is % not 180', r.liters; end if;

  -- Cash and credit must split the total, not overlap it.
  if r.cash_etb <> 15200  then raise exception 'cash_etb is % not 15200', r.cash_etb; end if;
  if r.credit_etb <> 1800 then raise exception 'credit_etb is % not 1800', r.credit_etb; end if;
  if r.cash_etb + r.credit_etb <> r.sales_etb then
    raise exception 'cash + credit (%) does not equal the total (%)',
      r.cash_etb + r.credit_etb, r.sales_etb;
  end if;

  -- A void is excluded from the money but counted, because a cashier whose
  -- sales keep being voided is telling you something.
  if r.voided_count <> 1 then raise exception 'voided_count is % not 1', r.voided_count; end if;

  if r.days_active <> 2 then raise exception 'days_active is % not 2', r.days_active; end if;
  if r.best_day <> v_to then
    raise exception 'best_day is % not today', r.best_day;
  end if;

  -- ---------------------------------------------------------------
  -- 2. it agrees with the sales report over the same range
  -- ---------------------------------------------------------------
  select sum(sales_etb) into v_n from report_staff(null, v_from, v_to);
  select sum(sales_etb) into v_m from report_sales(null, v_from, v_to);
  if v_n is distinct from v_m then
    raise exception 'staff report says % but the sales report says %', v_n, v_m;
  end if;

  -- ---------------------------------------------------------------
  -- 3. filtering by branch
  -- ---------------------------------------------------------------
  if (select count(*) from report_staff(v_s2, v_from, v_to)) <> 1 then
    raise exception 'a branch filter returned the wrong number of people';
  end if;
  if (select staff_name from report_staff(v_s2, v_from, v_to)) <> 'Chaltu' then
    raise exception 'the branch filter returned the wrong person';
  end if;

  -- ---------------------------------------------------------------
  -- 4. biggest seller first
  -- ---------------------------------------------------------------
  if (select staff_name from report_staff(null, v_from, v_to) limit 1) <> 'Abebe' then
    raise exception 'the report is not ordered by takings';
  end if;

  raise notice 'report_staff: ok';
end $$;

-- ---------------------------------------------------------------
-- 5. an operator sees only their own branch
-- ---------------------------------------------------------------
-- p_station_id is a filter, never a grant. Asking for someone else's branch
-- must not widen what comes back.
do $$
declare v_b_auth uuid; v_s1 uuid; v_n int; v_to date; v_from date;
begin
  select auth_user_id into v_b_auth from staff where full_name = 'Chaltu';
  select id into v_s1 from stations where name = 'Adama';
  v_to := (now() at time zone app_timezone())::date;
  v_from := v_to - 7;

  perform set_config('test.uid', v_b_auth::text, false);

  -- Asking for a branch that is not theirs does not widen anything, and does
  -- not silently hand back somebody else's figures: a non-admin always gets
  -- their own branch, the same way report_sales, list_tanks and get_prices
  -- all behave. The parameter is a filter for admins, never a grant.
  if exists (select 1 from report_staff(v_s1, v_from, v_to) where station_id <> (select station_id from staff where auth_user_id = v_b_auth)) then
    raise exception 'an operator saw another branch''s figures';
  end if;

  select count(*) into v_n from report_staff(null, v_from, v_to);
  if v_n <> 1 then
    raise exception 'an operator should see their own branch only, got % rows', v_n;
  end if;
  if (select staff_name from report_staff(null, v_from, v_to)) <> 'Chaltu' then
    raise exception 'an operator saw somebody else in the report';
  end if;

  raise notice 'branch scoping: ok';
end $$;
