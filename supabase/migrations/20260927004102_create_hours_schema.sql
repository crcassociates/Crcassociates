-- Phase 1: hours schema and Regular/OT calculation.
--
-- OT rules (see REQUIREMENTS.md). OT is calculated per employee + project + day:
--   * Weekday: hours on one project over the daily threshold (8) are OT.
--     Hours on different projects are never added together.
--   * Weekend: all hours on any project are OT.
--
-- Raken is a read-only source. These tables hold a copy of Raken data;
-- nothing here is ever written back to Raken.

-- Keeps updated_at current on every update.
create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.employees (
  id             bigint generated always as identity primary key,
  raken_id       text not null unique,
  full_name      text not null,
  employee_code  text,
  is_active      boolean not null default true,
  raw            jsonb,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
comment on table public.employees is 'Workers, copied from Raken.';
comment on column public.employees.raw is 'Original Raken record, kept for reference.';

create table public.projects (
  id              bigint generated always as identity primary key,
  raken_id        text not null unique,
  name            text not null,
  project_number  text,
  status          text,
  raw             jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on table public.projects is 'Projects, copied from Raken.';
comment on column public.projects.raw is 'Original Raken record, kept for reference.';

create table public.time_entries (
  id           bigint generated always as identity primary key,
  raken_id     text not null unique,
  employee_id  bigint not null references public.employees (id),
  project_id   bigint not null references public.projects (id),
  work_date    date not null,
  hours        numeric(5,2) not null check (hours >= 0 and hours <= 24),
  raw          jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table public.time_entries is 'Hours worked by an employee on a project on a day, copied from Raken.';
comment on column public.time_entries.raw is 'Original Raken record, kept for reference.';

create index time_entries_employee_date_idx on public.time_entries (employee_id, work_date);
create index time_entries_project_idx on public.time_entries (project_id);
create index time_entries_work_date_idx on public.time_entries (work_date);

-- OT settings are effective-dated: a new row applies from effective_from
-- onward, so reports for earlier dates keep the rules that applied then.
create table public.ot_rules (
  id                  bigint generated always as identity primary key,
  effective_from      date not null unique,
  daily_ot_threshold  numeric(4,2) not null
                      check (daily_ot_threshold > 0 and daily_ot_threshold <= 24),
  weekend_days        smallint[] not null
                      check (weekend_days <@ '{1,2,3,4,5,6,7}'::smallint[]),
  note                text,
  created_at          timestamptz not null default now()
);
comment on table public.ot_rules is
  'OT settings. Each row applies from effective_from until the next row''s date.';
comment on column public.ot_rules.daily_ot_threshold is
  'Weekday hours on one project above this are OT.';
comment on column public.ot_rules.weekend_days is
  'ISO weekdays where all hours are OT: 1 = Monday ... 6 = Saturday, 7 = Sunday.';

insert into public.ot_rules (effective_from, daily_ot_threshold, weekend_days, note)
values ('2000-01-01', 8, '{6,7}',
        'Initial rules: over 8 h on one project on a weekday is OT; all Saturday/Sunday hours are OT.');

create trigger employees_set_updated_at
  before update on public.employees
  for each row execute function public.set_updated_at();

create trigger projects_set_updated_at
  before update on public.projects
  for each row execute function public.set_updated_at();

create trigger time_entries_set_updated_at
  before update on public.time_entries
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Security
-- ---------------------------------------------------------------------------

-- No policies yet: only the service role (the Raken sync and the report
-- backend) can read or write. Read access for signed-in users will be added
-- together with the web page login.
alter table public.employees enable row level security;
alter table public.projects enable row level security;
alter table public.time_entries enable row level security;
alter table public.ot_rules enable row level security;

-- ---------------------------------------------------------------------------
-- Calculation
-- ---------------------------------------------------------------------------

-- One row per employee + project + day, split into Regular and OT hours.
create view public.daily_project_hours
with (security_invoker = true)
as
with daily as (
  select employee_id, project_id, work_date, sum(hours) as total_hours
  from public.time_entries
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
  d.total_hours
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
comment on view public.daily_project_hours is
  'Regular/OT hours per employee, project and day, using the OT rules in effect on that day.';

-- Totals per employee + project for a date range (inclusive).
create function public.hours_summary(p_from date, p_to date)
returns table (
  employee_id     bigint,
  employee_name   text,
  project_id      bigint,
  project_name    text,
  project_number  text,
  days_worked     bigint,
  regular_hours   numeric,
  ot_hours        numeric,
  total_hours     numeric
)
language sql
stable
set search_path = ''
as $$
  select
    d.employee_id,
    d.employee_name,
    d.project_id,
    d.project_name,
    d.project_number,
    count(*) as days_worked,
    sum(d.regular_hours),
    sum(d.ot_hours),
    sum(d.total_hours)
  from public.daily_project_hours d
  where d.work_date between p_from and p_to
  group by d.employee_id, d.employee_name, d.project_id, d.project_name, d.project_number
  order by d.employee_name, d.project_name;
$$;
comment on function public.hours_summary(date, date) is
  'Regular/OT/total hours per employee and project between two dates (inclusive).';

revoke execute on function public.hours_summary(date, date) from public, anon;
grant execute on function public.hours_summary(date, date) to authenticated, service_role;
