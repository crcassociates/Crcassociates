# CRC Associates – Raken Hours Calculator

## Background

CRC Associates records contractor time in **Raken**. Phase 1 pulls that time data
and calculates Regular and Overtime (OT) hours per employee, per project.

## Phase 1 – Hours calculation

### Overtime rules

OT is calculated **per employee, per project, per day**. Hours on different
projects are never added together to decide OT.

| Rule | Condition | Result |
|------|-----------|--------|
| 1 | Weekday (Mon–Fri), hours on one project ≤ 8 | All Regular |
| 2 | Weekday, hours on one project > 8 | First 8 Regular, the rest OT (for that project) |
| 3 | Weekday, several projects, daily total > 8 but each project ≤ 8 | All Regular, no OT |
| 4 | Weekend (Sat/Sun), any project | All hours OT |

### Examples

| Day | Hours worked | Regular | OT |
|-----|--------------|---------|----|
| Mon | A: 10h | A: 8h | A: 2h |
| Tue | A: 6h, B: 5h (11h total) | A: 6h, B: 5h | 0 |
| Wed | A: 9h, B: 2h | A: 8h, B: 2h | A: 1h |
| Sat | A: 5h | 0 | A: 5h |
| Sun | A: 3h, B: 2h | 0 | A: 3h, B: 2h |

### Data source

- Raken API. Credentials are stored as **Supabase Edge Function secrets**:
  `Client_ID` and `Raken_secret` (names are case-sensitive).
  Never commit credentials to this repo.
- **Read-only:** the system only reads data from Raken. It never creates,
  updates or deletes anything in Raken.

### Backend

- **Supabase** for all backend services: Postgres database, Auth, Edge Functions,
  scheduled jobs and Storage.
- Database tables: `employees`, `projects`, `time_entries` (copies of Raken data)
  and `ot_rules` (OT settings).
- Calculation: view `daily_project_hours` (Regular/OT per employee, project and
  day) and function `hours_summary(from, to)` (totals for a date range).
- **OT settings are effective-dated.** The 8 h threshold and weekend days are
  stored in `ot_rules`. A change applies from its start date, so reports for
  earlier dates keep the rules that applied then.
- Tables are locked to the backend (service role) until the web page login is built.
- `supabase/checks/ot_rules_check.sql` checks the calculation against the
  examples above, using sample data that it undoes afterwards.

### Raken sync

- Raken sign-in is OAuth with a **one-time browser approval** by a Raken user
  (Account Administrator recommended). After that the sync renews its own
  access. Raken rotates the renewal key, so it is stored in Supabase Vault
  and replaced after every renewal. The approval lasts 180 days and is
  extended by each renewal.
- Raken's permission has no read-only option, so read-only is enforced in our
  code: the Raken client can only send GET requests (plus the sign-in).
- Edge Function `raken-auth` creates the approval link and receives Raken's reply.
  Raken supports only this sign-in (approval code, then renewals). It doesn't
  check the reply address yet; if it starts to, the callback needs one fixed address.
- Edge Function `raken-sync` copies employees (Raken "members"), projects and
  time cards (one worker, one project, one day each) into Supabase:
  - Normal run: time cards changed since the last run, plus deletions.
  - Range run: re-reads all time cards dated in a range (used for the first import).
  - Time cards deleted in Raken are marked `deleted_at` and left out of all calculations.
  - Each run is logged in `sync_runs`.
- **Status (Sep 30, 2026):** connected with an Account Administrator and the
  renewal works, but Raken refuses every data request (403 on members,
  projects and time cards). Waiting on Raken to enable data access for our app.

### File upload (stand-in while the Raken API can't read data)

- An admin exports time cards from Raken's website (Excel or CSV) and uploads
  the file with the upload page in `upload/` (runs on this computer; see
  `upload/README.md`). Raken is not involved.
- Uploaded time cards go into the same tables as synced ones (`source = 'upload'`),
  so the OT calculation is the same. Each upload is logged in `imports`.
- A file replaces earlier uploads for its dates, so a corrected file never
  counts hours twice. An upload can be undone; what it replaced counts again.
- Refused: dates the Raken sync already covers, and files whose dates are more
  than a year apart. Rows with problems are skipped and listed.
- Employees and projects are matched by employee code / project number when
  the file has them, otherwise by name; new names are created.
- `supabase/checks/upload_check.sql` checks the upload logic.
- Raken's time card export (one row per time entry) has these columns: Last
  Name, First Name, EID, Day, Date, Project Name, Job #, Cost Code #, Cost Code
  Description, Classification, Shift, Pay Type, Hours, Start Time, End Time,
  Breaks, Meal Breaks, Total Break Time, WorkLog Name. The upload page uses
  First + Last Name (employee), EID (employee code), Project Name (project),
  Job # (project number), Date and Hours; Day is used to check the dates. All
  pay types (RT/OT/DT) are added up and OT is recalculated with our rules.

### Output

1. **Excel report**: per employee → per project → Regular / OT / Total, with a
   daily breakdown and totals for a chosen date range.
2. **Web page**: the same data, viewable in a browser. Design and clickable
   prototype (sample data): `design/README.md`, `design/ui-prototype.html`.

## Open items / future changes

- **Weekly OT (e.g. over 40 h/week):** not used for now; may be added later.
  Keep the rules configurable.
- **Company holidays:** to be discussed. Probably OT like weekends; needs a
  holiday list.
- **Raken data format:** confirm the fields (employee, project, date, hours,
  cost codes?) once the API is connected. Also check Raken's export format
  against the upload page with a real file.
- **Work logs:** OT is per project, so hours on two work logs of the same
  project on the same day are added together. Confirm this is right.
- **Pay types other than RT/OT/DT:** if Raken exports PTO or holiday hours, they
  would count as hours worked (the upload page warns). Decide how to treat them.
- **Uploads, then the sync:** when the Raken sync starts working, decide what
  happens to uploaded time cards for the same dates (replace them with synced
  ones), and match employees and projects created by uploads to Raken's records.
- **Timezone / overnight shifts:** which day an overnight shift counts toward.
- **Daily OT threshold:** 8 hours for now; configurable in `ot_rules`.
- **Raken's own pay types:** Raken marks hours as RT/OT/DT (the export's Pay
  Type). We recalculate Regular/OT from total hours using our rules, so the
  results can differ: a 10-hour weekday entered as RT 7 + OT 3 becomes 8
  Regular + 2 OT. Confirm this is wanted.
- **Approved time cards only?** Raken marks time cards as approved or not. For
  now all non-deleted time cards count; `all_approved` in the daily results
  shows whether each day is fully approved. Raken's time card export has no
  approval column, so uploaded time cards count as not approved.
- **First import start date:** how far back to copy time cards from Raken.
- **Sync schedule:** e.g. hourly; to be set up after the first import works.
- **Web page login:** decide who can sign in (invite-only is recommended)
  before read access is opened to signed-in users.
- **Pay week:** which day a week starts. The web page design assumes Monday to
  Sunday (week presets; also needed for weekly OT later).
- **OT rule changes in the web page:** the design lets admins schedule a change
  from a start date. Confirm, or keep rule changes database-only.
