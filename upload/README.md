# Upload time cards

A stand-in while the Raken sync can't read data: Raken accepts our sign-in but
refuses every data request (see `REQUIREMENTS.md`). Until Raken fixes that,
time cards come from a file exported from Raken's website.

Uploaded time cards go into the same Supabase tables as synced ones, so the
Regular/OT calculation, the Excel report and the web page work the same.
Raken is never changed.

## Use it

1. In Raken, export the time cards for the dates you want, as Excel or CSV.
2. Double-click **Start upload page.cmd** in this folder. A window opens (keep
   it open) and the page opens in your browser.
3. Drop the file on the page. Check the columns it found and change any that
   are wrong.
4. Click **Check with the database**. Nothing is saved yet. You see the dates,
   the number of time cards, Regular/OT hours, new employees and projects, and
   any rows that will be skipped, with the reason.
5. Click **Import**. Close the window when you're done.

Uploading the same dates again (for example a corrected file) replaces the
earlier upload for those dates, so hours are never counted twice. **Undo** under
Recent uploads takes an upload back out and brings back what it replaced.

## What the file needs

Raken's time card export works as it is. Its columns are matched like this:

| Raken column | Used as |
|---|---|
| First Name + Last Name | Employee ("Tomasz Abramowicz") |
| EID | Employee code |
| Project Name | Project |
| Job # | Project number |
| Date | Date |
| Hours | Hours |
| Day | Checks that each date falls on that weekday |
| Pay Type | Summary only; all hours are added up |
| Cost Code #, Cost Code Description, Classification, Shift, Start Time, End Time, Breaks, Meal Breaks, Total Break Time, WorkLog Name | Kept with each time card for reference |

OT is worked out per employee, project and day, so time on two work logs of
the same project on the same day counts together. The export has no approval
column, so uploaded time cards count as not approved.

For other files:

- **Required columns:** employee, project, date and hours. **Optional:**
  employee code, project number and approval status.
- Hours can be one total column or several to add up (for example ST, OT and
  DT). Raken's own ST/OT split is not used; OT is calculated with our rules.
- Dates such as `9/14/2026` are read month first (US). The preview shows the
  date range, so a mix-up is easy to spot.
- Title rows above the headings, blank rows and total rows are left out.
- A warning appears when a date doesn't match the file's Day column (weekend
  hours are all OT, so a misread date matters), and when a pay type other than
  RT, OT or DT (for example PTO) would be counted as hours worked.
- Rows with a problem (no date, more than 24 hours, and so on) are skipped and
  listed. The rest of the file still imports.
- A file is refused if its dates are more than a year apart (usually a typo),
  or if the Raken sync already has time cards for those dates.

## How it works

- `server.ps1` serves `index.html` at <http://localhost:4174> (this computer
  only). It gets the project's secret key from the Supabase CLI and adds it to
  the page's requests. The key never reaches the browser, and the page can only
  import, undo and read the upload history. Requests without the page's session
  token are refused.
- The page reads the file in the browser: Excel with SheetJS (loaded from
  `cdn.sheetjs.com`), CSV directly. Checking and saving happen in Supabase:
  `public.import_time_cards` (a dry run unless told otherwise),
  `public.undo_import` and the view `public.import_history`. Uploaded time cards
  have `source = 'upload'` and point to their row in `public.imports`.
- Needs the Supabase CLI, logged in on this computer, and internet access.
- Check the upload logic: `supabase db query --linked -f supabase/checks/upload_check.sql`
