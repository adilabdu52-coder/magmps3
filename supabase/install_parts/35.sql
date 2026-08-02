-- MAGPMS install 35 of 39 - run IN ORDER, one at a time.
-- Project: fendopitdcyoefpxuevd
-- No begin/commit: a transaction split across files rolls back.
--
-- Private notes, part 2: pinning, editing and deleting.
set search_path = public, extensions;
-- ---------------------------------------------------------------
-- changing and removing one
-- ---------------------------------------------------------------
-- Pinning is the "mark" - a note that matters stays at the top instead of
-- sinking under everything written since.
create or replace function admin_set_note(
  p_note_id uuid, p_body text default null, p_pinned boolean default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  if p_body is not null and trim(p_body) = '' then
    return json_build_object('success', false, 'message', 'a note cannot be emptied - delete it instead');
  end if;

  update branch_notes
     set body       = coalesce(nullif(trim(p_body), ''), body),
         pinned     = coalesce(p_pinned, pinned),
         updated_at = now()
   where id = p_note_id;

  if not found then return json_build_object('success', false, 'message', 'no such note'); end if;
  return json_build_object('success', true, 'message', 'note updated');
end; $$;

create or replace function admin_delete_note(p_note_id uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then return json_build_object('success', false, 'message', 'not authorised'); end if;
  delete from branch_notes where id = p_note_id;
  if not found then return json_build_object('success', false, 'message', 'no such note'); end if;
  return json_build_object('success', true, 'message', 'note deleted');
end; $$;

grant execute on function admin_add_note(text, uuid, boolean)    to authenticated;
grant execute on function admin_list_notes(uuid, int)            to authenticated;
grant execute on function admin_set_note(uuid, text, boolean)    to authenticated;
grant execute on function admin_delete_note(uuid)                to authenticated;



notify pgrst, 'reload schema';


