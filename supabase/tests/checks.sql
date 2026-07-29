\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

-- ---------------------------------------------------------------
-- seed: two branches, an admin and two operators
-- ---------------------------------------------------------------
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','owner@x.com'),
  ('22222222-2222-2222-2222-222222222222','abebe@x.com'),
  ('33333333-3333-3333-3333-333333333333','hana@x.com');

insert into stations (id, name, town) values
  ('aaaaaaaa-0000-0000-0000-000000000001','Adama','Adama'),
  ('bbbbbbbb-0000-0000-0000-000000000002','Hirna','Hirna');

insert into staff (id, full_name, auth_user_id, role, status, station_id) values
  ('a0000000-0000-0000-0000-000000000001','Owner',
   '11111111-1111-1111-1111-111111111111','admin','approved', null),
  ('a0000000-0000-0000-0000-000000000002','Abebe Kebede',
   '22222222-2222-2222-2222-222222222222','operator','approved','aaaaaaaa-0000-0000-0000-000000000001'),
  ('a0000000-0000-0000-0000-000000000003','Hana Tesfaye',
   '33333333-3333-3333-3333-333333333333','operator','approved','bbbbbbbb-0000-0000-0000-000000000002');

insert into tanks (station_id, tank_name, fuel_type, capacity_liters, current_liters) values
  ('aaaaaaaa-0000-0000-0000-000000000001','Tank 1','Diesel',50000,20000),
  ('bbbbbbbb-0000-0000-0000-000000000002','Tank 1','Diesel',50000, 5000);

-- THE SALE THIS IS ALL ABOUT: one minute after local midnight today.
-- In UTC that is 21:01 yesterday, so the old UTC boundary misses it.
insert into sales (station_id, staff_id, fuel_type, liters, total_etb, payment_method, created_at)
values ('aaaaaaaa-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002',
        'Diesel', 100, 9500, 'cash', local_day_start() + interval '1 minute');

-- A sale from three days ago, which belongs to neither "today".
insert into sales (station_id, staff_id, fuel_type, liters, total_etb, payment_method, created_at)
values ('aaaaaaaa-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002',
        'Diesel', 50, 4750, 'cash', local_day_start() - interval '3 days');

-- A voided sale today, which must not count anywhere.
insert into sales (station_id, staff_id, fuel_type, liters, total_etb, payment_method, voided, created_at)
values ('aaaaaaaa-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002',
        'Diesel', 999, 99999, 'cash', true, local_day_start() + interval '2 minutes');

-- A shift covering that first sale: metered 110 L, sold 100 L, variance +10.
insert into shifts (station_id, staff_id, opening_meter, closing_meter, opened_at, closed_at)
values ('aaaaaaaa-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002',
        1000, 1110, local_day_start(), local_day_start() + interval '8 hours');
-- An open shift, which must report no variance.
insert into shifts (station_id, staff_id, opening_meter, closing_meter, opened_at, closed_at)
values ('bbbbbbbb-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000003',
        500, null, now() - interval '2 hours', null);

insert into attendance (station_id, staff_id, check_in, check_out) values
  ('aaaaaaaa-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002',
   local_day_start(), local_day_start() + interval '8 hours'),
  ('bbbbbbbb-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000003',
   now() - interval '2 hours', null);

-- ---------------------------------------------------------------
-- checks
-- ---------------------------------------------------------------
set test.uid = '11111111-1111-1111-1111-111111111111';   -- the admin

select case when date_trunc('day', now()) - local_day_start() = interval '3 hours'
       then 'PASS' else 'FAIL' end
       || '  local day starts 3h before the UTC one (got '
       || (date_trunc('day', now()) - local_day_start())::text || ')';

select case when count(*) = 1 then 'PASS' else 'FAIL' end
       || '  the 00:01 sale is real and in the past'
  from sales where created_at < now() and total_etb = 9500;

-- The bug, demonstrated: the old boundary drops it, the new one keeps it.
select case when (select coalesce(sum(total_etb),0) from sales
                   where not voided and created_at >= date_trunc('day', now())) = 0
             and (select coalesce(sum(total_etb),0) from sales
                   where not voided and created_at >= local_day_start()) = 9500
       then 'PASS' else 'FAIL' end
       || '  old UTC boundary misses the early sale, local boundary keeps it';

select case when sales_today_etb = 9500 then 'PASS' else 'FAIL' end
       || '  admin_dashboard counts it (got ' || sales_today_etb::text || ', voided excluded)'
  from admin_dashboard() where station_name = 'Adama';

select case when sales_today_etb = 0 then 'PASS' else 'FAIL' end
       || '  the other branch stays at zero'
  from admin_dashboard() where station_name = 'Hirna';

-- The dashboard tile and the report must now agree.
select case when (select sum(sales_today_etb) from admin_dashboard())
                = (select coalesce(sum(sales_etb),0) from report_sales(
                     null, (now() at time zone app_timezone())::date,
                           (now() at time zone app_timezone())::date))
       then 'PASS' else 'FAIL' end
       || '  dashboard tile and report agree for today';

select case when count(*) = 1 and max(sales_etb) = 9500 then 'PASS' else 'FAIL' end
       || '  report excludes the voided sale'
  from report_sales(null, (now() at time zone app_timezone())::date,
                          (now() at time zone app_timezone())::date);

select case when count(*) = 2 then 'PASS' else 'FAIL' end
       || '  report over 7 days sees both trading days (got ' || count(*)::text || ')'
  from report_sales(null, (now() at time zone app_timezone())::date - 6,
                          (now() at time zone app_timezone())::date);

-- shifts
select case when metered_liters = 110 and sold_liters = 100 and variance_liters = 10
       then 'PASS' else 'FAIL' end
       || '  closed shift variance is metered minus sold (+10)'
  from list_shifts() where station_name = 'Adama';

select case when variance_liters is null and metered_liters is null
       then 'PASS' else 'FAIL' end
       || '  open shift reports no variance'
  from list_shifts() where station_name = 'Hirna';

select case when count(*) = 2 then 'PASS' else 'FAIL' end
       || '  admin sees both branches'' shifts'
  from list_shifts();

select case when count(*) = 1 and max(station_name) = 'Adama' then 'PASS' else 'FAIL' end
       || '  admin can narrow to one branch'
  from list_shifts('aaaaaaaa-0000-0000-0000-000000000001');

select case when count(*) = 2 then 'PASS' else 'FAIL' end
       || '  attendance lists both branches for an admin'
  from list_attendance();

select case when hours between 7.9 and 8.1 then 'PASS' else 'FAIL' end
       || '  attendance hours computed (got ' || hours::text || ')'
  from list_attendance() where station_name = 'Adama';

select case when hours > 1.9 and check_out is null then 'PASS' else 'FAIL' end
       || '  an open check-in counts hours up to now'
  from list_attendance() where station_name = 'Hirna';

-- ---------------------------------------------------------------
-- p_station_id is a filter, never a grant
-- ---------------------------------------------------------------
set test.uid = '33333333-3333-3333-3333-333333333333';   -- Hana, operator at Hirna

select case when count(*) = 1 and max(station_name) = 'Hirna' then 'PASS' else 'FAIL' end
       || '  operator passing another branch''s id still sees only their own (shifts)'
  from list_shifts('aaaaaaaa-0000-0000-0000-000000000001');

select case when count(*) = 1 and max(station_name) = 'Hirna' then 'PASS' else 'FAIL' end
       || '  same for attendance'
  from list_attendance('aaaaaaaa-0000-0000-0000-000000000001');

select case when count(*) = 0 then 'PASS' else 'FAIL' end
       || '  operator gets no other branch''s sales from the report'
  from report_sales('aaaaaaaa-0000-0000-0000-000000000001');

select case when count(*) = 1 then 'PASS' else 'FAIL' end
       || '  operator sees only their own branch on the dashboard'
  from admin_dashboard();

-- ---------------------------------------------------------------
-- signed out
-- ---------------------------------------------------------------
set test.uid = '';

select case when count(*) = 0 then 'PASS' else 'FAIL' end
       || '  a caller with no session gets nothing from list_shifts'
  from list_shifts();

select case when count(*) = 0 then 'PASS' else 'FAIL' end
       || '  ...and nothing from report_sales'
  from report_sales();

-- my_sales_today for the cashier who made the 00:01 sale
set test.uid = '22222222-2222-2222-2222-222222222222';

select case when count(*) = 1 and max(total_etb) = 9500 then 'PASS' else 'FAIL' end
       || '  the till''s My Day now shows the early-morning sale'
  from my_sales_today() where not voided;
