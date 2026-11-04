-- =====================================================================
--  UCAPS Parking Ops — Open shift requests (run after scheduling_migration.sql)
--  Staff see published open shifts for their group and can request them;
--  a manager approves one request, which assigns the shift.
--  Safe to re-run.
-- =====================================================================

create table if not exists public.shift_requests (
  id          uuid primary key default gen_random_uuid(),
  shift_id    uuid not null references public.shifts(id) on delete cascade,
  staff_id    uuid not null references public.staff_members(id) on delete cascade,
  note        text,
  status      text not null default 'Requested' check (status in ('Requested','Approved','Declined')),
  reviewed_by text,
  reviewed_at timestamptz,
  created_at  timestamptz not null default now(),
  unique (shift_id, staff_id)
);
create index if not exists shift_requests_shift_idx on public.shift_requests(shift_id);

create or replace function public.my_staff_grp() returns text
  language sql stable security definer set search_path = public
as $$ select grp from public.staff_members where email = public.jwt_email() and active limit 1 $$;
revoke execute on function public.my_staff_grp() from public, anon;
grant execute on function public.my_staff_grp() to authenticated;

-- Staff can see published OPEN shifts for their own group (or any group if either side has none)
drop policy if exists "staff read open shifts" on public.shifts;
create policy "staff read open shifts" on public.shifts for select to authenticated
  using (staff_id is null and published and public.my_staff_id() is not null
         and (grp is null or public.my_staff_grp() is null or grp = public.my_staff_grp()));

alter table public.shift_requests enable row level security;
drop policy if exists "ops admin all" on public.shift_requests;
create policy "ops admin all" on public.shift_requests for all to authenticated
  using (public.is_ops_admin()) with check (public.is_ops_admin());
drop policy if exists "staff read own" on public.shift_requests;
create policy "staff read own" on public.shift_requests for select to authenticated
  using (staff_id = public.my_staff_id());
grant select, insert, update, delete on public.shift_requests to authenticated;

-- Staff: request an open shift
create or replace function public.staff_request_shift(p_shift uuid, p_note text default null)
returns public.shift_requests
  language plpgsql security definer set search_path = public
as $$
declare me uuid := public.my_staff_id(); mg text := public.my_staff_grp(); s public.shifts; r public.shift_requests;
begin
  if me is null then raise exception 'Not on the staff list'; end if;
  select * into s from public.shifts where id = p_shift;
  if s.id is null or s.staff_id is not null or not s.published then raise exception 'That shift is no longer open'; end if;
  if s.grp is not null and mg is not null and s.grp <> mg then raise exception 'That shift is for another group'; end if;
  if s.shift_date < (now() at time zone 'America/New_York')::date then raise exception 'That shift has already passed'; end if;
  insert into public.shift_requests(shift_id, staff_id, note)
    values (p_shift, me, nullif(trim(p_note),''))
    on conflict (shift_id, staff_id) do update
      set status = 'Requested', note = excluded.note, created_at = now(), reviewed_by = null, reviewed_at = null
      where public.shift_requests.status <> 'Approved'
    returning * into r;
  if r.id is null then raise exception 'You already have this shift'; end if;
  return r;
end $$;

-- Staff: withdraw a pending request
create or replace function public.staff_withdraw_request(p_request uuid) returns void
  language plpgsql security definer set search_path = public
as $$
declare me uuid := public.my_staff_id();
begin
  if me is null then raise exception 'Not on the staff list'; end if;
  delete from public.shift_requests where id = p_request and staff_id = me and status = 'Requested';
end $$;

-- Manager: approve a request → assigns the shift (one slot), declines the rest when it's filled
create or replace function public.ops_approve_shift_request(p_request uuid) returns uuid
  language plpgsql security definer set search_path = public
as $$
declare r public.shift_requests; s public.shifts; assigned uuid; who text := public.jwt_email();
begin
  if not public.is_ops_admin() then raise exception 'Managers only'; end if;
  select * into r from public.shift_requests where id = p_request for update;
  if r.id is null or r.status <> 'Requested' then raise exception 'That request is no longer pending'; end if;
  select * into s from public.shifts where id = r.shift_id for update;
  if s.id is null or s.staff_id is not null then raise exception 'That shift has already been filled'; end if;

  if coalesce(s.open_slots,1) > 1 then
    -- more than one slot: give this person their own copy, keep the open shift with one fewer slot
    insert into public.shifts(staff_id, grp, shift_date, start_time, end_time, label, color, template_id, event_id,
                              lots, checklist, notes, unpaid_break, open_slots, published)
      values (r.staff_id, s.grp, s.shift_date, s.start_time, s.end_time, s.label, s.color, s.template_id, s.event_id,
              s.lots, s.checklist, s.notes, s.unpaid_break, 1, true)
      returning id into assigned;
    update public.shifts set open_slots = open_slots - 1 where id = s.id;
  else
    update public.shifts set staff_id = r.staff_id, open_slots = 1, published = true where id = s.id;
    assigned := s.id;
    update public.shift_requests set status = 'Declined', reviewed_by = who, reviewed_at = now()
      where shift_id = s.id and id <> r.id and status = 'Requested';
  end if;
  -- the request stays linked to the open shift, so the person can't ask for a second slot of it
  update public.shift_requests set status = 'Approved', reviewed_by = who, reviewed_at = now() where id = r.id;
  return assigned;
end $$;

revoke all on function public.staff_request_shift(uuid,text) from public, anon;
revoke all on function public.staff_withdraw_request(uuid) from public, anon;
revoke all on function public.ops_approve_shift_request(uuid) from public, anon;
grant execute on function public.staff_request_shift(uuid,text) to authenticated;
grant execute on function public.staff_withdraw_request(uuid) to authenticated;
grant execute on function public.ops_approve_shift_request(uuid) to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='shift_requests') then
    alter publication supabase_realtime add table public.shift_requests;
  end if;
end $$;
