# Web page design

A clickable prototype of the web page (Output 2 in `REQUIREMENTS.md`), with
sample data. It is a design to review, not the real app: nothing in it talks to
Raken or Supabase.

## Open the prototype

- Double-click `ui-prototype.html`. It works offline in any modern browser.
- Or, in the Claude app, start the preview `ui-prototype` (`.claude/launch.json`
  runs `serve.ps1`, a small local-only server).

The **Prototype** button (bottom left) switches the situation (all good, sync
failing, Raken not connected), the signed-in role (admin, viewer) and the
theme. The same works from the address bar, for example
`ui-prototype.html?scenario=failed&role=viewer&theme=dark#/sync`.

The sample numbers use the same rules as the view `daily_project_hours`.
"Today" is fixed at Sat, Sep 26, 2026. **Marcus Reyes, week of Sep 14** is the
example week from `REQUIREMENTS.md` and `supabase/checks/ot_rules_check.sql`,
so the screens can be checked against the expected results.

## Who uses it, for what

1. **Payroll:** pick last week, check that time cards are approved and the data
   is current, export the Excel file.
2. **Owner and project managers:** Regular and OT hours by employee or by
   project, for any date range.
3. **Anyone checking a number:** see exactly why hours count as OT.
4. **Admins:** keep the Raken connection working, manage OT rules and users.

## Screens

| Screen | What it shows | Data |
|---|---|---|
| Sign in | Invite-only; sign-in link sent by email, no passwords | Supabase Auth |
| Hours | Date range, totals, employee → project table (or project → employee), filters, search | `hours_summary`, `daily_project_hours` |
| Employee timesheet | One table per week: projects × days, Regular/OT per cell, day totals | `daily_project_hours` |
| Project | Same layout: employees × days | `daily_project_hours` |
| Day details (side panel) | How that day was calculated, other projects that day, the Raken time cards | `time_entries`, `ot_rules` |
| Export to Excel | Preview of the file: Summary and Daily sheets | same as the screen |
| Raken sync | Connection, data counts, sync now, re-import dates, sync history | Vault (non-secret fields), `sync_runs` |
| Settings → OT rules | Current rules, examples, rule history, schedule a change | `ot_rules` |
| Settings → Users | Invite people, Admin or Viewer role | new (see below) |

## Design decisions

- **The per-project OT rule is always explained.** The timesheet has a day
  total row with a note wherever the combined total would look like OT
  (Tue: 11 h on two projects, no OT). The day panel spells out each result.
  The OT rules page shows the examples, calculated with the current rule.
- **Problems stand out, the rest stays quiet.** A banner shows unapproved time
  cards (still counted, as today's rule says) with a "Show them" filter. A red
  banner on every page says when the sync is failing and how old the numbers
  are. The top bar always shows when Raken data was last synced.
- **Read-only is visible.** There is no way to edit Raken data. The day panel
  says to fix hours in Raken; the sync page says the app only reads.
- **OT rules are effective-dated, as in the database.** Changes are scheduled
  from a start date (next Monday by default). A start date that is today or in
  the past warns that already-paid weeks will be recalculated. Only future
  changes can be cancelled; history stays.
- **Links keep the view.** Date range and grouping are in the address, so a
  view can be bookmarked or sent to someone.
- **Weeks run Monday to Sunday**, matching the database's weekday numbers.
  Presets: this week, last week (the default), last 2 weeks, this month, last
  month, or a custom range; arrows step to the previous or next period.
- **Numbers:** hours always with 2 decimals, aligned; zero OT is greyed so real
  OT stands out.

## Look and feel

- Regular hours are blue (`#2a78d6`), OT orange (`#eb6834`); dark theme
  `#3987e5` / `#d95926`. The pair was checked for color-blind separation and
  contrast. Text is never in these colors; a small swatch beside it carries the
  meaning. Red, amber and green are only used for status, always with an icon
  and a label.
- Warm neutral greys, black main buttons, the system font (Segoe UI on
  Windows). Light and dark themes. Works down to phone width.
- Keyboard and screen reader basics: labelled controls, table captions, focus
  kept inside dialogs, Esc closes.
- All colors are CSS variables at the top of `ui-prototype.html`; company
  colors or a logo can be dropped in there.

## What building it for real needs

- **Read access and roles.** Read policies for signed-in users on `employees`,
  `projects`, `time_entries`, `ot_rules` and `sync_runs`, plus a small users
  table with each person's role (Admin or Viewer).
- **Report data.** `hours_summary` gives the employee + project totals. The
  employee-level "Days" (distinct days) and the unapproved counts come from
  `daily_project_hours`, or the function can be extended.
- **Admin actions go through the server.** Sync now, re-import dates and the
  Raken approval link need an endpoint that checks the user is an admin and then
  calls `raken-sync` / `raken-auth`. Those functions accept only the service
  key, which must never reach the browser.
- **Connection status** comes from an endpoint that returns only who connected
  and when, never the tokens.
- **OT rule changes:** admins can add rows to `ot_rules`, and delete only rows
  that have not started yet.
- **Excel file:** generated on the server with the Summary and Daily sheets and
  a header (date range, OT rules used, "Raken data as of").
- Optional: a `triggered_by` column on `sync_runs` to show who ran a manual sync.

## Open questions

1. **Pay week:** does the week run Monday to Sunday? This affects the presets
   and future weekly OT.
2. **Sign-in:** invite-only with emailed sign-in links, and two roles (Admin,
   Viewer). Is that right?
3. **OT rule changes:** should admins make them in the web page, or only in the
   database?
4. **Excel layout:** are the Summary and Daily sheets what payroll needs? Any
   columns missing (cost codes, for example)?
5. **Branding:** a logo or company colors to use?
