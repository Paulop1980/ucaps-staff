-- =====================================================================
--  UCAPS Parking Ops — per-person "clocks in" setting
--  Only staff with requires_punch = true see the clock in/out button and
--  are tracked for late / missed punches. Defaults: Parking Events/Enforcement
--  and Work Study Students (gate calls) clock in; everyone else doesn't.
--  Safe to re-run (only sets defaults the first time the column is added).
-- =====================================================================

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema='public' and table_name='staff_members' and column_name='requires_punch') then
    alter table public.staff_members add column requires_punch boolean not null default false;
    update public.staff_members set requires_punch = true
      where grp in ('Parking Events/Enforcement', 'Work Study Students');
  end if;
end $$;

-- Clock-in is only allowed for people who are set to clock in
create or replace function public.staff_clock_in(p_shift uuid default null,
  p_lat double precision default null, p_lng double precision default null, p_acc double precision default null)
returns public.punches
  language plpgsql security definer set search_path = public
as $$
declare me uuid := public.my_staff_id(); r public.punches;
begin
  if me is null then raise exception 'Not on the staff list'; end if;
  if not exists (select 1 from public.staff_members where id = me and requires_punch) then
    raise exception 'You don''t need to clock in';
  end if;
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
revoke all on function public.staff_clock_in(uuid,double precision,double precision,double precision) from public, anon;
grant execute on function public.staff_clock_in(uuid,double precision,double precision,double precision) to authenticated;
