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

### Output

1. **Excel report**: per employee → per project → Regular / OT / Total, with a
   daily breakdown and totals for a chosen date range.
2. **Web page**: the same data, viewable in a browser.

## Open items / future changes

- **Weekly OT (e.g. over 40 h/week):** not used for now; may be added later.
  Keep the rules configurable.
- **Company holidays:** to be discussed. Probably OT like weekends; needs a
  holiday list.
- **Raken auth type:** Client ID + secret suggests OAuth client credentials;
  confirm against the Raken API docs.
- **Raken data format:** confirm the fields (employee, project, date, hours,
  cost codes?) once the API is connected.
- **Timezone / overnight shifts:** which day an overnight shift counts toward.
- **Daily OT threshold:** 8 hours for now; keep it configurable.
