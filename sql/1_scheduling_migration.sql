-- =====================================================================
--  UCAPS Parking Ops — Staff Scheduling & Timeclock migration
--  Run once in the Supabase SQL editor (project kljduohcijypnhuaqlfo).
--  Safe to re-run: every statement is idempotent.
--
--  What it does
--   1. Adds an ops_admins list. Everyone who has a Parking Ops login
--      today is copied into it automatically.
--   2. LOCKS DOWN the existing Parking Ops tables so only ops_admins can
--      read/write them. (Today any signed-in account can. Once staff can
--      sign in with an email code, that would expose events, VIP lists,
--      reservations, etc.) The public parking-request form is unchanged.
--   3. Creates the scheduling tables: staff_members, shift_templates,
--      shifts, time_off, day_notes, punches, shift_checks.
--   4. Staff (non-admin) accounts can only see their own published
--      shifts, their own punches/checklist ticks, and their own time-off.
--      Clock-in/out and checklist ticks go through server functions that
--      stamp the server's clock, so times can't be faked from a phone.
--   5. Adds the new tables to Realtime.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Managers (full Parking Ops access)
-- ---------------------------------------------------------------------
create table if not exists public.ops_admins (
  id         uuid primary key default gen_random_uuid(),
  email      text not null unique check (email = lower(email)),
  added_at   timestamptz not null default now()
);
insert into public.ops_admins(email)
  select distinct lower(email) from auth.users where email is not null
  on conflict (email) do nothing;

create or replace function public.jwt_email() returns text
  language sql stable set search_path = public
as $$ select lower(coalesce(auth.jwt() ->> 'email', '')) $$;

create or replace function public.is_ops_admin() returns boolean
  language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.ops_admins where email = public.jwt_email()) $$;

alter table public.ops_admins enable row level security;
drop policy if exists "ops admin all" on public.ops_admins;
create policy "ops admin all" on public.ops_admins for all to authenticated
  using (public.is_ops_admin()) with check (public.is_ops_admin());

-- ---------------------------------------------------------------------
-- 2. Lock existing Parking Ops tables to managers only
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['events','global_settings','holidays','lot_impacts','lots','maintenance_items',
                           'parking_requests','reservations','staff_assignments','vip_sign_deployments','vip_signs']
  loop
    if to_regclass('public.'||t) is null then continue; end if;
    execute format('drop policy if exists "staff select" on public.%I', t);
    execute format('drop policy if exists "staff insert" on public.%I', t);
    execute format('drop policy if exists "staff update" on public.%I', t);
    execute format('drop policy if exists "staff delete" on public.%I', t);
    execute format('drop policy if exists "ops admin all" on public.%I', t);
    execute format('create policy "ops admin all" on public.%I for all to authenticated using (public.is_ops_admin()) with check (public.is_ops_admin())', t);
  end loop;
end $$;
-- (The anon "public submit request" policy on parking_requests is left as-is.)

-- ---------------------------------------------------------------------
-- 3. Scheduling tables
-- ---------------------------------------------------------------------
create table if not exists public.staff_members (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,                      -- "Last, First" like Teams
  email      text not null unique check (email = lower(email)),
  grp        text,                               -- Shifts group, e.g. "Parking Events/Enforcement"
  title      text,
  phone      text,
  active     boolean not null default true,
  notes      text,
  created_at timestamptz not null default now()
);

create table if not exists public.shift_templates (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,                    -- e.g. "North Enforcement 8A-12P"
  grp          text,
  start_time   text not null,                    -- 'HH:MM' (same as events)
  end_time     text not null,
  color        text not null default '2. Blue',  -- Teams Shifts theme colour name
  lots         text[] not null default '{}',     -- lots on the route (Lots Reference names)
  checklist    text[] not null default '{}',     -- route / duty checklist items
  notes        text,
  unpaid_break integer not null default 0,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

create table if not exists public.shifts (
  id           uuid primary key default gen_random_uuid(),
  staff_id     uuid references public.staff_members(id) on delete cascade,  -- null = open shift
  grp          text,
  shift_date   date not null,
  start_time   text not null,
  end_time     text not null,                    -- end <= start means it ends the next day
  label        text,
  color        text not null default '2. Blue',
  template_id  uuid references public.shift_templates(id) on delete set null,
  event_id     uuid references public.events(id) on delete set null,
  lots         text[] not null default '{}',     -- copied from the template, editable per shift
  checklist    text[] not null default '{}',
  notes        text,
  unpaid_break integer not null default 0,
  open_slots   integer not null default 1,
  published    boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists shifts_date_idx  on public.shifts(shift_date);
create index if not exists shifts_staff_idx on public.shifts(staff_id, shift_date);

create table if not exists public.time_off (
  id           uuid primary key default gen_random_uuid(),
  staff_id     uuid not null references public.staff_members(id) on delete cascade,
  start_date   date not null,
  end_date     date not null,
  start_time   text,                             -- null = all day
  end_time     text,
  reason       text not null default 'Requested time off',
  notes        text,
  status       text not null default 'Approved' check (status in ('Requested','Approved','Denied')),
  reviewed_by  text,
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now(),
  check (end_date >= start_date)
);
create index if not exists time_off_staff_idx on public.time_off(staff_id, start_date);

create table if not exists public.day_notes (
  id         uuid primary key default gen_random_uuid(),
  note_date  date not null unique,
  note       text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.punches (
  id           uuid primary key default gen_random_uuid(),
  staff_id     uuid not null references public.staff_members(id) on delete cascade,
  shift_id     uuid references public.shifts(id) on delete set null,
  clock_in     timestamptz not null default now(),
  clock_out    timestamptz,
  in_lat double precision,  in_lng double precision,  in_acc double precision,
  out_lat double precision, out_lng double precision, out_acc double precision,
  note         text,
  edited_by    text,                             -- set when a manager corrects a punch
  edited_at    timestamptz,
  created_at   timestamptz not null default now(),
  check (clock_out is null or clock_out > clock_in)
);
create index if not exists punches_staff_idx on public.punches(staff_id, clock_in);
-- one open punch per person
create unique index if not exists punches_one_open on public.punches(staff_id) where clock_out is null;

create table if not exists public.shift_checks (
  id         uuid primary key default gen_random_uuid(),
  shift_id   uuid not null references public.shifts(id) on delete cascade,
  staff_id   uuid references public.staff_members(id) on delete cascade,
  item_idx   integer not null,
  item       text,
  checked_at timestamptz not null default now(),
  unique (shift_id, item_idx)
);

-- ---------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------
create or replace function public.my_staff_id() returns uuid
  language sql stable security definer set search_path = public
as $$ select id from public.staff_members where email = public.jwt_email() and active limit 1 $$;

do $$
declare t text;
begin
  foreach t in array array['staff_members','shift_templates','shifts','time_off','day_notes','punches','shift_checks']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "ops admin all" on public.%I', t);
    execute format('create policy "ops admin all" on public.%I for all to authenticated using (public.is_ops_admin()) with check (public.is_ops_admin())', t);
  end loop;
end $$;

drop policy if exists "staff read self" on public.staff_members;
create policy "staff read self" on public.staff_members for select to authenticated
  using (email = public.jwt_email() and active);

drop policy if exists "staff read own published" on public.shifts;
create policy "staff read own published" on public.shifts for select to authenticated
  using (staff_id = public.my_staff_id() and published);

drop policy if exists "staff read own" on public.time_off;
create policy "staff read own" on public.time_off for select to authenticated
  using (staff_id = public.my_staff_id());
drop policy if exists "staff request" on public.time_off;
create policy "staff request" on public.time_off for insert to authenticated
  with check (staff_id = public.my_staff_id() and status = 'Requested' and reviewed_by is null and reviewed_at is null);
drop policy if exists "staff cancel pending" on public.time_off;
create policy "staff cancel pending" on public.time_off for delete to authenticated
  using (staff_id = public.my_staff_id() and status = 'Requested');

drop policy if exists "staff read own" on public.punches;
create policy "staff read own" on public.punches for select to authenticated
  using (staff_id = public.my_staff_id());

drop policy if exists "staff read own" on public.shift_checks;
create policy "staff read own" on public.shift_checks for select to authenticated
  using (staff_id = public.my_staff_id());

-- ---------------------------------------------------------------------
-- 5. Server functions for the staff app
-- ---------------------------------------------------------------------

-- Lets the sign-in screen say "not on the staff list" before sending a code.
create or replace function public.staff_check_email(p_email text) returns boolean
  language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.staff_members where email = lower(trim(p_email)) and active)
$$;

create or replace function public.staff_clock_in(p_shift uuid default null,
  p_lat double precision default null, p_lng double precision default null, p_acc double precision default null)
returns public.punches
  language plpgsql security definer set search_path = public
as $$
declare me uuid := public.my_staff_id(); r public.punches;
begin
  if me is null then raise exception 'Not on the staff list'; end if;
  if exists (select 1 from public.punches where staff_id = me and clock_out is null) then
    raise exception 'You are already clocked in';
  end if;
  if p_shift is not null and not exists (select 1 from public.shifts where id = p_shift and staff_id = me) then
    raise exception 'That shift is not yours';
  end if;
  insert into public.punches(staff_id, shift_id, clock_in, in_lat, in_lng, in_acc)
    values (me, p_shift, now(), p_lat, p_lng, p_acc) returning * into r;
  return r;
end $$;

create or replace function public.staff_clock_out(
  p_lat double precision default null, p_lng double precision default null, p_acc double precision default null,
  p_note text default null)
returns public.punches
  language plpgsql security definer set search_path = public
as $$
declare me uuid := public.my_staff_id(); r public.punches;
begin
  if me is null then raise exception 'Not on the staff list'; end if;
  update public.punches
     set clock_out = greatest(now(), clock_in + interval '1 second'),
         out_lat = p_lat, out_lng = p_lng, out_acc = p_acc,
         note = coalesce(nullif(trim(p_note),''), note)
   where staff_id = me and clock_out is null
   returning * into r;
  if r.id is null then raise exception 'You are not clocked in'; end if;
  return r;
end $$;

create or replace function public.staff_toggle_check(p_shift uuid, p_idx integer, p_done boolean)
returns void
  language plpgsql security definer set search_path = public
as $$
declare me uuid := public.my_staff_id(); s public.shifts;
begin
  if me is null then raise exception 'Not on the staff list'; end if;
  select * into s from public.shifts where id = p_shift and staff_id = me and published;
  if s.id is null then raise exception 'That shift is not yours'; end if;
  if p_idx < 0 or p_idx >= coalesce(array_length(s.checklist,1),0) then raise exception 'No such checklist item'; end if;
  if p_done then
    insert into public.shift_checks(shift_id, staff_id, item_idx, item)
      values (p_shift, me, p_idx, s.checklist[p_idx+1])
      on conflict (shift_id, item_idx) do update set checked_at = now(), staff_id = excluded.staff_id;
  else
    delete from public.shift_checks where shift_id = p_shift and item_idx = p_idx;
  end if;
end $$;

-- Restrictions & notes for one day (events with lots/enforcement notes, lot impacts,
-- holidays, manager day note) — without giving staff the events table itself.
create or replace function public.staff_day_info(p_date date) returns json
  language plpgsql stable security definer set search_path = public
as $$
begin
  if public.my_staff_id() is null and not public.is_ops_admin() then
    raise exception 'Not on the staff list';
  end if;
  return json_build_object(
    'events', coalesce((select json_agg(json_build_object(
        'title', e.title, 'start_time', e.start_time, 'end_time', e.end_time,
        'lots', e.lots, 'enforcement_note', e.enforcement_note) order by e.start_time)
      from public.events e
      where coalesce(e.status,'') <> 'Cancelled'
        and p_date between e.start_date and coalesce(e.end_date, e.start_date)), '[]'::json),
    'impacts', coalesce((select json_agg(json_build_object(
        'lots', i.lots, 'type', i.type, 'description', i.description))
      from public.lot_impacts i
      where i.status in ('Active','Planned')
        and p_date between i.start_date and coalesce(i.end_date, i.start_date)), '[]'::json),
    'holiday', (select h.label from public.holidays h where h.holiday_date = p_date limit 1),
    'day_note', (select d.note from public.day_notes d where d.note_date = p_date)
  );
end $$;

revoke all on function public.staff_check_email(text) from public;
revoke all on function public.staff_clock_in(uuid,double precision,double precision,double precision) from public;
revoke all on function public.staff_clock_out(double precision,double precision,double precision,text) from public;
revoke all on function public.staff_toggle_check(uuid,integer,boolean) from public;
revoke all on function public.staff_day_info(date) from public;
grant execute on function public.staff_check_email(text) to anon, authenticated;
grant execute on function public.staff_clock_in(uuid,double precision,double precision,double precision) to authenticated;
grant execute on function public.staff_clock_out(double precision,double precision,double precision,text) to authenticated;
grant execute on function public.staff_toggle_check(uuid,integer,boolean) to authenticated;
grant execute on function public.staff_day_info(date) to authenticated;
-- Supabase also grants anon direct EXECUTE on new functions; only the sign-in email check should be callable signed-out.
revoke execute on function public.is_ops_admin() from public, anon;
revoke execute on function public.my_staff_id() from public, anon;
revoke execute on function public.jwt_email() from public, anon;
revoke execute on function public.staff_clock_in(uuid,double precision,double precision,double precision) from anon;
revoke execute on function public.staff_clock_out(double precision,double precision,double precision,text) from anon;
revoke execute on function public.staff_toggle_check(uuid,integer,boolean) from anon;
revoke execute on function public.staff_day_info(date) from anon;
grant execute on function public.is_ops_admin() to authenticated;
grant execute on function public.my_staff_id() to authenticated;
grant execute on function public.jwt_email() to authenticated;

grant select, insert, update, delete on public.ops_admins, public.staff_members, public.shift_templates,
  public.shifts, public.time_off, public.day_notes, public.punches, public.shift_checks to authenticated;

-- ---------------------------------------------------------------------
-- 6. Realtime
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['staff_members','shift_templates','shifts','time_off','day_notes','punches','shift_checks']
  loop
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

commit;

-- Check: who has full Parking Ops access after this ran?
select email as "Parking Ops managers" from public.ops_admins order by email;
