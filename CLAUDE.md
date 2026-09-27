# CLAUDE.md

Project: CRC Associates Raken hours calculator. See `REQUIREMENTS.md` for the
business rules and open items. Keep it updated when requirements change.

Key rule: OT is calculated per employee + project + day. On weekdays, hours on a
single project over 8 are OT; hours across projects are never combined. All
weekend hours are OT.

- Never commit Raken credentials or any secrets.
- Keep the OT threshold, weekend days and future weekly-OT and holiday rules configurable.
- On this machine, if `git` isn't found, refresh PATH first:
  `$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')`
