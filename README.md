# UCAPS Parking Ops & Staff Scheduling

UMass Lowell UCard, Access & Parking Services — event parking operations, staff scheduling and timeclock.
Static pages hosted on GitHub Pages; data lives in Supabase.

| Page | Who | Link |
|---|---|---|
| `index.html` — Parking Ops | Managers (email + password) | https://paulop1980.github.io/ucaps-staff/ |
| `staff/index.html` — Staff app | Scheduled staff (code emailed to them) | https://paulop1980.github.io/ucaps-staff/staff/ |
| Public parking request form | Anyone | https://paulop1980.github.io/ucaps-staff/?request=1 |

## What's in Parking Ops → Schedule
- Week board with shift templates (route checklists from the Parking Enforcement Routes guide), copy last week, publish
- Day notes generated from events, lot impacts and holidays; ⚑ flags when a route covers a "no tickets" lot
- Time off, open shifts staff can request, and shift release requests — all approved here
- Timesheet: scheduled vs. clocked hours to check against HR Direct
- Import/export in the Teams Shifts format

## Staff app
Sign in with an emailed code → today's shift, clock in/out (with location if allowed), route checklist,
"Today on campus" restrictions, schedule, open shifts to pick up, release requests, time-off requests, hours.

## Security
The Supabase key in the pages is the public "publishable" key — that's expected. Access is enforced by
Row Level Security in the database: only accounts in `ops_admins` can see Parking Ops data; staff see only
their own shifts, punches, requests and time off. Public sign-up is off; sign-in accounts are created by the
`staff-accounts` Edge Function when a manager adds someone in Parking Ops.

## Database setup (already applied to the live project)
Run in order in the Supabase SQL editor — each is safe to re-run:
1. `sql/1_scheduling_migration.sql` — managers list, locks existing tables to managers, scheduling tables, timeclock functions
2. `sql/2_open_shift_requests_migration.sql` — open shifts staff can request
3. `sql/3_shift_release_migration.sql` — staff ask to release a shift → becomes an open shift
4. `sql/4_route_templates_update.sql` — enforcement shift templates from the July 2026 route guide
5. `sql/5_clock_in_setting.sql` — per-person "Clocks in" setting (on for Parking Enforcement and Work Study / gate calls)

Edge Function: `supabase/functions/staff-accounts` (deployed with JWT verification off; it checks the caller is a manager itself).

Supabase Auth settings: Email provider on, **"Allow new users to sign up" off**, `{{ .Token }}` in the Magic Link
email template, custom SMTP configured.
