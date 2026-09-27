-- Raken sync support.
--
-- Raken is READ-ONLY: the sync only reads from Raken and writes into these
-- tables. Nothing here is ever sent back to Raken.

-- ---------------------------------------------------------------------------
-- Extra time card fields
-- ---------------------------------------------------------------------------

alter table public.time_entries
  add column approved          boolean,
  add column raken_updated_at  timestamptz,
  add column deleted_at        timestamptz;

comment on column public.time_entries.approved is 'Approval flag from Raken.';
comment on column public.time_entries.raken_updated_at is 'When the time card was last changed in Raken.';
comment on column public.time_entries.deleted_at is
  'Set when the time card was deleted in Raken. Deleted entries are ignored in all calculations.';

-- Same calculation as before, now ignoring deleted time cards and showing
-- whether every time card behind the row is approved.
create or replace view public.daily_project_hours
with (security_invoker = true)
as
with daily as (
  select
    employee_id,
    project_id,
    work_date,
    sum(hours) as total_hours,
    bool_and(coalesce(approved, false)) as all_approved
  from public.time_entries
  where deleted_at is null
  group by employee_id, project_id, work_date
)
select
  d.employee_id,
  e.full_name as employee_name,
  d.project_id,
  p.name as project_name,
  p.project_number,
  d.work_date,
  x.is_weekend,
  case when x.is_weekend then 0
       else least(d.total_hours, x.threshold) end as regular_hours,
  case when x.is_weekend then d.total_hours
       else greatest(d.total_hours - x.threshold, 0) end as ot_hours,
  d.total_hours,
  d.all_approved
from daily d
join public.employees e on e.id = d.employee_id
join public.projects p on p.id = d.project_id
left join lateral (
  select o.daily_ot_threshold, o.weekend_days
  from public.ot_rules o
  where o.effective_from <= d.work_date
  order by o.effective_from desc
  limit 1
) r on true
cross join lateral (
  select
    coalesce(r.daily_ot_threshold, 8) as threshold,
    extract(isodow from d.work_date)::smallint
      = any (coalesce(r.weekend_days, '{6,7}')) as is_weekend
) x;

-- ---------------------------------------------------------------------------
-- Sync run log
-- ---------------------------------------------------------------------------

create table public.sync_runs (
  id           bigint generated always as identity primary key,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  status       text not null default 'running'
               check (status in ('running', 'success', 'error')),
  mode         text not null check (mode in ('incremental', 'range')),
  params       jsonb,
  summary      jsonb,
  error        text
);
comment on table public.sync_runs is 'One row per Raken sync run.';

create index sync_runs_started_at_idx on public.sync_runs (started_at desc);

alter table public.sync_runs enable row level security;

-- Starts a sync run, or returns null if one is already running or the last
-- successful run was less than p_min_interval ago.
create function public.raken_sync_start(p_mode text, p_params jsonb, p_min_interval interval)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_id bigint;
begin
  perform pg_advisory_xact_lock(hashtext('raken_sync'));

  -- A run with no finish after 30 minutes has crashed.
  update public.sync_runs
     set status = 'error', finished_at = now(), error = 'Stopped without finishing'
   where status = 'running' and started_at < now() - interval '30 minutes';

  if exists (select 1 from public.sync_runs where status = 'running') then
    return null;
  end if;

  if exists (select 1 from public.sync_runs
              where status = 'success' and started_at > now() - p_min_interval) then
    return null;
  end if;

  insert into public.sync_runs (mode, params)
  values (p_mode, p_params)
  returning id into v_id;

  return v_id;
end;
$$;

-- Marks time cards that Raken reported as deleted.
create function public.raken_mark_deleted(p_raken_ids text[])
returns integer
language sql
set search_path = ''
as $$
  with changed as (
    update public.time_entries
       set deleted_at = now()
     where raken_id = any (p_raken_ids) and deleted_at is null
    returning 1
  )
  select count(*)::integer from changed;
$$;

-- After a full re-read of a date range, marks entries in that range that
-- Raken no longer returns. A later sync restores them if they reappear.
create function public.raken_mark_missing_deleted(p_from date, p_to date, p_seen text[])
returns integer
language sql
set search_path = ''
as $$
  with changed as (
    update public.time_entries
       set deleted_at = now()
     where work_date between p_from and p_to
       and deleted_at is null
       and not (raken_id = any (p_seen))
    returning 1
  )
  select count(*)::integer from changed;
$$;

-- ---------------------------------------------------------------------------
-- Raken sign-in tokens, stored encrypted in Supabase Vault
-- ---------------------------------------------------------------------------

-- Raken rotates refresh tokens, so the latest one must be saved after every
-- refresh. Edge Function secrets are read-only, hence Vault.
create function public.raken_tokens_get()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select decrypted_secret::jsonb
  from vault.decrypted_secrets
  where name = 'raken_oauth'
  limit 1;
$$;

create function public.raken_tokens_save(p_tokens jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select id into v_id from vault.secrets where name = 'raken_oauth';
  if v_id is null then
    perform vault.create_secret(p_tokens::text, 'raken_oauth', 'Raken sign-in tokens for the read-only sync');
  else
    perform vault.update_secret(v_id, p_tokens::text);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Only the backend (service role) may call the sync functions
-- ---------------------------------------------------------------------------

revoke execute on function public.raken_sync_start(text, jsonb, interval) from public, anon, authenticated;
revoke execute on function public.raken_mark_deleted(text[]) from public, anon, authenticated;
revoke execute on function public.raken_mark_missing_deleted(date, date, text[]) from public, anon, authenticated;
revoke execute on function public.raken_tokens_get() from public, anon, authenticated;
revoke execute on function public.raken_tokens_save(jsonb) from public, anon, authenticated;

grant execute on function public.raken_sync_start(text, jsonb, interval) to service_role;
grant execute on function public.raken_mark_deleted(text[]) to service_role;
grant execute on function public.raken_mark_missing_deleted(date, date, text[]) to service_role;
grant execute on function public.raken_tokens_get() to service_role;
grant execute on function public.raken_tokens_save(jsonb) to service_role;
