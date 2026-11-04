-- =====================================================================
--  UCAPS Parking Ops — Shift release requests (run after open_shift_requests_migration.sql)
--  Staff ask to give up one of their upcoming shifts; a manager approves,
--  which turns it into a published open shift others can request.
--  Safe to re-run.
-- =====================================================================

create table if not exists public.shift_releases (
  id          uuid primary key default gen_random_uuid(),
  shift_id    uuid not null references public.shifts(id) on delete cascade,
  staff_id    uuid not null references public.staff_members(id) on delete cascade,
  reason      text,
  status      text not null default 'Requested' check (status in ('Requested','Approved','Denied')),
  reviewed_by text,
  reviewed_at timestamptz,
  created_at  timestamptz not null default now(),
  unique (shift_id, staff_id)
);
create index if not exists shift_releases_shift_idx on public.shift_releases(shift_id);

alter table public.shift_releases enable row level security;
drop policy if exists "ops admin all" on public.shift_releases;
create policy "ops admin all" on public.shift_releases for all to authenticated
  using (public.is_ops_admin()) with check (public.is_ops_admin());
drop policy if exists "staff read own" on public.shift_releases;
create policy "staff read own" on public.shift_releases for select to authenticated
  using (staff_id = public.my_staff_id());
grant select, insert, update, delete on public.shift_releases to authenticated;

-- Staff: ask to release one of my upcoming shifts
create or replace function public.staff_request_release(p_shift uuid, p_reason text default null)
returns public.shift_releases
  language plpgsql security definer set search_path = public
as $$
declare me uuid := public.my_staff_id(); s public.shifts; r public.shift_releases;
begin
  if me is null then raise exception 'Not on the staff list'; end if;
  select * into s from public.shifts where id = p_shift;
  if s.id is null or s.staff_id is distinct from me or not s.published then raise exception 'That shift is not yours'; end if;
  if (s.shift_date + s.start_time::time) <= (now() at time zone 'America/New_York') then
    raise exception 'That shift has already started';
  end if;
  insert into public.shift_releases(shift_id, staff_id, reason)
    values (p_shift, me, nullif(trim(p_reason),''))
    on conflict (shift_id, staff_id) do update
      set status = 'Requested', reason = excluded.reason, created_at = now(), reviewed_by = null, reviewed_at = null
    returning * into r;
  return r;
end $$;

-- Staff: cancel a pending release request
create or replace function public.staff_cancel_release(p_release uuid) returns void
  language plpgsql security definer set search_path = public
as $$
declare me uuid := public.my_staff_id();
begin
  if me is null then raise exception 'Not on the staff list'; end if;
  delete from public.shift_releases where id = p_release and staff_id = me and status = 'Requested';
end $$;

-- Manager: approve → the shift becomes a published open shift for its group
create or replace function public.ops_approve_release(p_release uuid) returns uuid
  language plpgsql security definer set search_path = public
as $$
declare r public.shift_releases; s public.shifts; who text := public.jwt_email();
begin
  if not public.is_ops_admin() then raise exception 'Managers only'; end if;
  select * into r from public.shift_releases where id = p_release for update;
  if r.id is null or r.status <> 'Requested' then raise exception 'That release request is no longer pending'; end if;
  select * into s from public.shifts where id = r.shift_id for update;
  if s.id is null or s.staff_id is distinct from r.staff_id then raise exception 'That shift is no longer assigned to this person'; end if;
  update public.shifts
     set staff_id = null, open_slots = 1, published = true,
         grp = coalesce(s.grp, (select grp from public.staff_members where id = r.staff_id))
   where id = s.id;
  delete from public.shift_checks where shift_id = s.id;
  -- clear old pick-up requests on this shift so it starts fresh as an open shift
  delete from public.shift_requests where shift_id = s.id;
  update public.shift_releases set status = 'Approved', reviewed_by = who, reviewed_at = now() where id = r.id;
  return s.id;
end $$;

revoke all on function public.staff_request_release(uuid,text) from public, anon;
revoke all on function public.staff_cancel_release(uuid) from public, anon;
revoke all on function public.ops_approve_release(uuid) from public, anon;
grant execute on function public.staff_request_release(uuid,text) to authenticated;
grant execute on function public.staff_cancel_release(uuid) to authenticated;
grant execute on function public.ops_approve_release(uuid) to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='shift_releases') then
    alter publication supabase_realtime add table public.shift_releases;
  end if;
end $$;
