-- Checks for 0018: the notebook is admin-only, and stays that way.

do $$
declare
  v_admin_auth uuid := gen_random_uuid();
  v_op_auth uuid := gen_random_uuid();
  v_s1 uuid; v_s2 uuid; v_res json; v_id uuid; v_n int;
begin
  insert into auth.users (id, email) values (v_admin_auth,'ad@x.com'), (v_op_auth,'o@x.com');
  insert into stations (name) values ('Adama') returning id into v_s1;
  insert into stations (name) values ('Hirna') returning id into v_s2;
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_admin_auth,'Owner','admin','approved',null);
  insert into staff (auth_user_id, full_name, role, status, station_id)
  values (v_op_auth,'Abebe','operator','approved',v_s1);

  -- ---------------------------------------------------------------
  -- 1. a cashier can neither write nor read
  -- ---------------------------------------------------------------
  -- This is the whole point. A note may say "check Abebe's readings on pump
  -- 4", and Abebe finding it would be worse than not writing it.
  perform set_config('test.uid', v_op_auth::text, false);

  v_res := admin_add_note('secret', v_s1, false);
  if (v_res ->> 'message') <> 'not authorised' then
    raise exception 'a cashier wrote a private note: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 2. an admin writes one
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_admin_auth::text, false);

  v_res := admin_add_note('   ', v_s1, false);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'an empty note was saved: %', v_res;
  end if;

  v_res := admin_add_note('Pumps 1 and 2 are Benzil, the rest Diesel', v_s1, true);
  if (v_res ->> 'success') <> 'true' then raise exception 'a valid note failed: %', v_res; end if;
  v_id := (v_res ->> 'id')::uuid;

  perform admin_add_note('Shift starts 6am and ends 6pm', null, false);
  perform admin_add_note('Hirna only: gauge on tank 3 reads low', v_s2, false);

  -- A branch that does not exist is refused rather than filed under nothing.
  v_res := admin_add_note('x', '00000000-0000-0000-0000-000000000000'::uuid, false);
  if (v_res ->> 'message') <> 'no such branch' then
    raise exception 'a note was filed against a branch that does not exist: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 3. a branch sees its own notes plus the business-wide ones
  -- ---------------------------------------------------------------
  -- "Shift starts at 6" is as true at Hirna as anywhere and should not have
  -- to be written five times.
  select count(*) into v_n from admin_list_notes(v_s1, 100);
  if v_n <> 2 then raise exception 'Adama sees % notes, expected 2', v_n; end if;

  select count(*) into v_n from admin_list_notes(v_s2, 100);
  if v_n <> 2 then raise exception 'Hirna sees % notes, expected 2', v_n; end if;

  -- Adama must not see Hirna's.
  if exists (select 1 from admin_list_notes(v_s1, 100) where body like '%tank 3%') then
    raise exception 'one branch can read another branch''s notes';
  end if;

  select count(*) into v_n from admin_list_notes(null, 100);
  if v_n <> 3 then raise exception 'all-branches view shows % notes, expected 3', v_n; end if;

  -- ---------------------------------------------------------------
  -- 4. pinned first
  -- ---------------------------------------------------------------
  if (select body from admin_list_notes(v_s1, 100) limit 1)
     <> 'Pumps 1 and 2 are Benzil, the rest Diesel' then
    raise exception 'a pinned note is not at the top';
  end if;

  -- ---------------------------------------------------------------
  -- 5. editing, unpinning and deleting
  -- ---------------------------------------------------------------
  v_res := admin_set_note(v_id, 'Pumps 1 and 2 Benzil - checked', null);
  if (v_res ->> 'success') <> 'true' then raise exception 'editing failed: %', v_res; end if;
  if (select body from admin_list_notes(v_s1, 100) where id = v_id) <> 'Pumps 1 and 2 Benzil - checked' then
    raise exception 'the edit did not stick';
  end if;
  if (select updated_at from admin_list_notes(v_s1, 100) where id = v_id) is null then
    raise exception 'an edited note does not say it was edited';
  end if;

  -- Emptying a note is refused: deleting is the way to remove one, and a
  -- blank row in a notebook is just confusing.
  v_res := admin_set_note(v_id, '   ', null);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'a note was emptied instead of deleted: %', v_res;
  end if;

  -- A missing id must not report success - the lesson from 0011.
  v_res := admin_set_note('00000000-0000-0000-0000-000000000000'::uuid, 'x', null);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'editing a note that does not exist reported success: %', v_res;
  end if;

  v_res := admin_delete_note(v_id);
  if (v_res ->> 'success') <> 'true' then raise exception 'delete failed: %', v_res; end if;
  v_res := admin_delete_note(v_id);
  if (v_res ->> 'success') <> 'false' then
    raise exception 'deleting the same note twice reported success: %', v_res;
  end if;

  -- ---------------------------------------------------------------
  -- 6. and a cashier still cannot read what is left
  -- ---------------------------------------------------------------
  perform set_config('test.uid', v_op_auth::text, false);
  select count(*) into v_n from admin_list_notes(null, 100);
  if v_n <> 0 then raise exception 'a cashier read % private note(s)', v_n; end if;

  v_res := admin_delete_note(gen_random_uuid());
  if (v_res ->> 'message') <> 'not authorised' then
    raise exception 'a cashier reached the delete: %', v_res;
  end if;

  raise notice 'private notes: ok';
end $$;
