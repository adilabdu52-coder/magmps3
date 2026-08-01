-- MAGPMS install 27 of 29 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Nozzles, part 1: the table, ten per branch, and the columns that tie a
-- shift and a sale to one.
set search_path = public, extensions;
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
      -- "Pump 1" rather than "N1": the label is read aloud at the forecourt,
      -- and it should be the word the people using it already say.
      insert into nozzles (station_id, label, fuel_type)
      values (st.id, 'Pump ' || i, fuels[1 + ((i - 1) % array_length(fuels, 1))]);
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
   -- Shortest label first, then alphabetical: plain text sorting puts
   -- "Pump 10" between "Pump 1" and "Pump 2", which reads as a mistake to
   -- anybody scanning the list for their pump.
   order by st.name, length(n.label), n.label;
$$;


