-- MAGPMS install 18 of 19 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
set search_path = public, extensions;

do $$
declare
  v_total int;
  v_with  int;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'staff'
                    and column_name = 'password_hash') then
    raise notice 'staff.password_hash is already gone - nothing to do';
    return;
  end if;

  select count(*) into v_total from staff;
  execute 'select count(*) from staff where password_hash is not null' into v_with;

  raise notice 'staff rows: %, of which % still carry an old password hash', v_total, v_with;
  if v_with = 0 then
    raise notice 'none left - this drop is tidying, not remediation';
  end if;
end $$;

alter table staff drop column if exists password_hash;

notify pgrst, 'reload schema';

notify pgrst, 'reload schema';

do $report$
declare
  v_stations int; v_tanks int; v_fns int; v_rls int;
begin
  select count(*) into v_stations from stations;
  select count(*) into v_tanks    from tanks;
  select count(*) into v_fns from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('me','current_staff','is_admin','current_station',
                       'admin_dashboard','list_shifts','list_attendance',
                       'report_sales','record_sale','local_day_start');
  select count(*) into v_rls from pg_tables
   where schemaname = 'public' and rowsecurity;

  raise notice '--------------------------------------------------';
  raise notice 'branches ................ % (expect 5)', v_stations;
  raise notice 'tanks ................... % (expect 20)', v_tanks;
  raise notice 'key functions ........... % of 10', v_fns;
  raise notice 'tables with RLS on ...... %', v_rls;
  raise notice '--------------------------------------------------';
  if v_stations = 5 and v_tanks = 20 and v_fns = 10 then
    raise notice 'READY. Next: sign up at the app, then promote yourself to admin.';
  else
    raise notice 'SOMETHING IS MISSING - scroll up for the error that stopped it';
  end if;
end $report$;
