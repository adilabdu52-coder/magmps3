-- Checks for 0021: the shape of the trade, and the rows underneath it.

do $$
declare
  v_admin uuid := gen_random_uuid();
  v_cash  uuid := gen_random_uuid();
  v_ad uuid; v_hi uuid; v_op uuid; v_op2 uuid; v_n1 uuid;
  v_today date; r record; v_n int; v_total bigint; v_label text;
begin
  insert into auth.users (id, email) values (v_admin,'ad@x.com'), (v_cash,'c@x.com');
  insert into stations (name) values ('Adama') returning id into v_ad;
  insert into stations (name) values ('Hirna') returning id into v_hi;

  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_admin,'Owner','admin','approved',null)
  on conflict (auth_user_id) do update
    set full_name = excluded.full_name, role = excluded.role,
        status = excluded.status, station_id = excluded.station_id
  returning id into v_op2;
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_cash,'Abebe','operator','approved',v_ad)
  on conflict (auth_user_id) do update
    set full_name = excluded.full_name, role = excluded.role,
        status = excluded.status, station_id = excluded.station_id
  returning id into v_op;

  insert into nozzles (station_id, label, fuel_type) values (v_ad,'Pump 1','Diesel')
    returning id into v_n1;

  v_today := (now() at time zone app_timezone())::date;

  -- Two live Diesel sales today at Adama, one of them on credit; one voided
  -- sale the same day; one Benzil sale yesterday; one at Hirna today.
  insert into sales (station_id, staff_id, nozzle_id, fuel_type, liters, total_etb,
                     payment_method, voided, created_at)
  values (v_ad, v_op, v_n1, 'Diesel', 100, 10000, 'cash',     false, now()),
         (v_ad, v_op, v_n1, 'Diesel',  50,  5000, 'credit',   false, now()),
         (v_ad, v_op, v_n1, 'Diesel', 999, 99900, 'cash',     true,  now()),
         (v_ad, v_op, v_n1, 'Benzil',  20,  1800, 'telebirr', false, now() - interval '1 day'),
         (v_hi, v_op, null, 'Diesel',  10,  1000, 'cash',     false, now());

  -- ---------------------------------------------------------------
  -- 1. admin only
  -- ---------------------------------------------------------------
  -- Row-level access to every sale at every branch is a different thing from
  -- a summary of your own, which is what Reports already gives a cashier.
  perform set_config('test.uid', v_cash::text, false);
  if exists (select 1 from research_totals(null, v_today - 7, v_today, 'day')) then
    raise exception 'a cashier can see the research totals';
  end if;
  if exists (select 1 from research_sales(null, v_today - 7, v_today)) then
    raise exception 'a cashier can read every sale at every branch';
  end if;

  perform set_config('test.uid', v_admin::text, false);

  -- ---------------------------------------------------------------
  -- 2. the money leaves voids out; the voids are still counted
  -- ---------------------------------------------------------------
  -- 999 L at 99,900 would swamp everything if a void leaked into the money,
  -- and dropping it entirely would hide that a mistake was made at all.
  select * into r from research_totals(v_ad, v_today, v_today, 'day')
   where fuel_type = 'Diesel';
  if r.sale_count <> 2 then raise exception 'sale_count is % not 2', r.sale_count; end if;
  if r.liters <> 150 then raise exception 'litres are % not 150', r.liters; end if;
  if r.sales_etb <> 15000 then raise exception 'takings are % not 15000', r.sales_etb; end if;
  if r.credit_etb <> 5000 then raise exception 'credit is % not 5000', r.credit_etb; end if;
  if r.voided_count <> 1 then raise exception 'voided_count is % not 1', r.voided_count; end if;
  if r.voided_liters <> 999 then
    raise exception 'voided litres are % not 999', r.voided_liters;
  end if;

  -- ---------------------------------------------------------------
  -- 3. one branch, or all of them
  -- ---------------------------------------------------------------
  select count(*) into v_n from research_totals(null, v_today, v_today, 'day');
  if v_n <> 2 then raise exception 'today across all branches is % rows not 2', v_n; end if;
  select count(*) into v_n from research_totals(v_hi, v_today, v_today, 'day');
  if v_n <> 1 then raise exception 'Hirna alone is % rows not 1', v_n; end if;

  -- ---------------------------------------------------------------
  -- 4. day, week and month
  -- ---------------------------------------------------------------
  -- Yesterday's Benzil and today's Diesel are separate days but the same
  -- month, so the month bucket must fold them onto one start date.
  select count(distinct bucket_start) into v_n
    from research_totals(v_ad, v_today - 1, v_today, 'day');
  if v_n <> 2 then raise exception 'two days bucketed as % day(s)', v_n; end if;

  select count(distinct bucket_start) into v_n
    from research_totals(v_ad, v_today - 1, v_today, 'month')
   where bucket_start = date_trunc('month', v_today::timestamp)::date;
  if v_n <> 1 then raise exception 'the month bucket did not fold the days together'; end if;

  select bucket_label into v_label
    from research_totals(v_ad, v_today, v_today, 'month') limit 1;
  if v_label <> to_char(v_today, 'YYYY-MM') then
    raise exception 'the month label reads %', v_label;
  end if;

  -- A typo must not empty the page. It falls back to the day.
  select count(*) into v_n from research_totals(v_ad, v_today, v_today, 'fortnight');
  if v_n = 0 then raise exception 'an unrecognised bucket returned nothing'; end if;

  -- ---------------------------------------------------------------
  -- 5. the rows underneath
  -- ---------------------------------------------------------------
  -- Research is for looking at what happened, and what happened includes the
  -- mistakes - so the voided sale IS here, marked, where the totals left it
  -- out of the money.
  select count(*) into v_n from research_sales(v_ad, v_today, v_today);
  if v_n <> 3 then raise exception 'today at Adama is % rows not 3', v_n; end if;
  if not exists (select 1 from research_sales(v_ad, v_today, v_today) where voided) then
    raise exception 'the voided sale is missing from the rows';
  end if;

  -- The price on the day, worked back from what was actually taken. Pricing
  -- an old sale at today's rate would quietly rewrite history.
  select * into r from research_sales(v_ad, v_today, v_today)
   where not voided and payment_method = 'cash';
  if r.unit_price <> 100 then raise exception 'unit price is % not 100', r.unit_price; end if;
  if r.staff_name <> 'Abebe' then raise exception 'the seller is %', r.staff_name; end if;
  if r.nozzle_label <> 'Pump 1' then raise exception 'the pump is %', r.nozzle_label; end if;

  -- ---------------------------------------------------------------
  -- 6. total_rows is the whole match, not the page
  -- ---------------------------------------------------------------
  -- Asking for 1 and being told "1 row" reads as a total and is not one.
  select total_rows into v_total from research_sales(v_ad, v_today, v_today, null, null, 1, 0);
  if v_total <> 3 then raise exception 'total_rows on a page of 1 reads % not 3', v_total; end if;

  select count(*) into v_n from research_sales(v_ad, v_today, v_today, null, null, 1, 0);
  if v_n <> 1 then raise exception 'a limit of 1 returned % rows', v_n; end if;
  select count(*) into v_n from research_sales(v_ad, v_today, v_today, null, null, 10, 2);
  if v_n <> 1 then raise exception 'offset 2 of 3 returned % rows', v_n; end if;

  -- ---------------------------------------------------------------
  -- 7. narrowing it down
  -- ---------------------------------------------------------------
  select count(*) into v_n
    from research_sales(null, v_today - 1, v_today, null, 'Benzil');
  if v_n <> 1 then raise exception 'the fuel filter returned % rows not 1', v_n; end if;
  select count(*) into v_n
    from research_sales(null, v_today, v_today, v_op2, null);
  if v_n <> 0 then raise exception 'the staff filter matched somebody else''s sales'; end if;

  -- Newest first: a research list read top-down should start at what just
  -- happened, not at whatever came first a month ago.
  if exists (
    select 1 from (
      select sold_at, lag(sold_at) over () as prev
        from research_sales(v_ad, v_today - 1, v_today)
    ) q where q.prev is not null and q.sold_at > q.prev
  ) then
    raise exception 'the rows are not newest first';
  end if;

  raise notice 'research: ok';
end $$;
