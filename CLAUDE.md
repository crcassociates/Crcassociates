# CLAUDE.md

Project: CRC Associates Raken hours calculator. See `REQUIREMENTS.md` for the
business rules and open items. Keep it updated when requirements change.

**HARD RULE: Raken is READ-ONLY.** Never create, update or delete anything in
Raken, not even for testing. Only read data from it with GET requests. The one
allowed non-GET call is the OAuth sign-in that gets an access token. The Raken
API client must enforce this in code. All storage and processing happens in Supabase.

Key rule: OT is calculated per employee + project + day. On weekdays, hours on a
single project over 8 are OT; hours across projects are never combined. All
weekend hours are OT.

- Never commit Raken credentials or any secrets.
- Keep the OT threshold, weekend days and future weekly-OT and holiday rules configurable.
- Supabase project ref `hedpqzmsbtymuvqbxrqg` (linked). Supabase CLI is at
  `%LOCALAPPDATA%\Programs\supabase\supabase.exe`. It connects to the remote DB with a
  temporary login role, so no DB password is needed. Raken secrets are Edge Function
  secrets `Client_ID` and `Raken_secret`.
- On this machine, if `git` or `supabase` isn't found, refresh PATH first:
  `$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')`
