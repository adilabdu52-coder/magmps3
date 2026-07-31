-- MAGPMS install 8 of 19 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

create or replace function my_sales_today()
returns table (id uuid, fuel_type text, liters numeric, total_etb numeric,
               payment_method text, voided boolean, created_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select s.id, s.fuel_type, s.liters, s.total_etb, s.payment_method,
         coalesce(s.voided,false), s.created_at
  from sales s
  where s.staff_id = (select id from current_staff())
    and s.created_at >= date_trunc('day', now())
  order by s.created_at desc;
$$;

create or replace function my_open_shift()
returns table (id uuid, opened_at timestamptz, opening_meter numeric)
language sql stable security definer set search_path = public
as $$
  select sh.id, sh.opened_at, sh.opening_meter
  from shifts sh
  where sh.staff_id = (select id from current_staff()) and sh.closed_at is null
  order by sh.opened_at desc limit 1;
$$;

create or replace function my_attendance_status()
returns table (id uuid, check_in timestamptz, check_out timestamptz)
language sql stable security definer set search_path = public
as $$
  select a.id, a.check_in, a.check_out
  from attendance a
  where a.staff_id = (select id from current_staff())
  order by a.check_in desc limit 1;
$$;
