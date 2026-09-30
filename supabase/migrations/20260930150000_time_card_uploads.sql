-- Time cards from uploaded files (Excel or CSV exported from Raken).
--
-- A stand-in while the Raken API refuses data access: an admin exports time
-- cards from Raken's website and uploads the file with the local upload page
-- (upload/). Uploaded time cards go into the same tables as synced ones, so
-- the Regular/OT calculation does not change.
--
-- Raken stays READ-ONLY: nothing here talks to Raken.

-- ---------------------------------------------------------------------------
-- Upload log
-- ---------------------------------------------------------------------------

create table public.imports (
  id              bigint generated always as identity primary key,
  file_name       text not null,
  uploaded_at     timestamptz not null default now(),
  uploaded_by     text,
  date_from       date not null,
  date_to         date not null,
  rows_in_file    integer not null default 0,
  rows_imported   integer not null default 0,
  rows_skipped    integer not null default 0,
  cards_replaced  integer not null default 0,
  summary         jsonb,
  undone_at       timestamptz
);
comment on table public.imports is 'One row per uploaded time card file.';
comment on column public.imports.date_from is 'First date in the file. The upload replaces earlier uploads from date_from to date_to.';

alter table public.imports enable row level security;

-- ---------------------------------------------------------------------------
-- Records can come from the Raken sync or from an upload
-- ---------------------------------------------------------------------------

alter table public.employees
  alter column raken_id drop not null,
  add column source text not null default 'raken' check (source in ('raken', 'upload'));
alter table public.employees
  add constraint employees_raken_id_matches_source check ((raken_id is not null) = (source = 'raken'));

alter table public.projects
  alter column raken_id drop not null,
  add column source text not null default 'raken' check (source in ('raken', 'upload'));
alter table public.projects
  add constraint projects_raken_id_matches_source check ((raken_id is not null) = (source = 'raken'));

alter table public.time_entries
  alter column raken_id drop not null,
  add column source text not null default 'raken' check (source in ('raken', 'upload')),
  add column import_id bigint references public.imports (id),
  add column replaced_by bigint references public.imports (id);
alter table public.time_entries
  add constraint time_entries_source_ids check (
    (source = 'raken' and raken_id is not null and import_id is null)
    or (source = 'upload' and raken_id is null and import_id is not null));

comment on column public.time_entries.source is 'raken = copied by the Raken sync; upload = from an uploaded file.';
comment on column public.time_entries.replaced_by is 'The later upload that replaced this uploaded time card (same dates).';

create index time_entries_import_idx on public.time_entries (import_id);
create index time_entries_replaced_by_idx on public.time_entries (replaced_by);

-- The range sync only marks its own time cards as deleted, never uploaded ones.
create or replace function public.raken_mark_missing_deleted(p_from date, p_to date, p_seen text[])
returns integer
language sql
set search_path = ''
as $$
  with changed as (
    update public.time_entries
       set deleted_at = now()
     where source = 'raken'
       and work_date between p_from and p_to
       and deleted_at is null
       and not (raken_id = any (p_seen))
    returning 1
  )
  select count(*)::integer from changed;
$$;

-- ---------------------------------------------------------------------------
-- Importing a file
-- ---------------------------------------------------------------------------

-- Safe conversions for uploaded values: null instead of an error.
create function public.upload_date(p_value text)
returns date
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null or p_value !~ '^\d{4}-\d{2}-\d{2}$' then
    return null;
  end if;
  return p_value::date;
exception
  when others then
    return null;
end;
$$;

create function public.upload_number(p_value text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case when p_value ~ '^-?\d{1,6}(\.\d+)?$' then p_value::numeric end;
$$;

-- Does the work for import_time_cards. Call import_time_cards instead.
create function public.import_time_cards_run(p_file_name text, p_rows jsonb, p_uploaded_by text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_rows            integer;
  v_ok              integer;
  v_from            date;
  v_to              date;
  v_problem         text;
  v_raken_cards     integer;
  v_import_id       bigint;
  v_replaced        integer := 0;
  v_replaced_ids    bigint[] := '{}';
  v_new_employees   jsonb := '[]';
  v_new_projects    jsonb := '[]';
  v_hours           jsonb := '{"regular": 0, "ot": 0, "total": 0}';
  v_warnings        jsonb := '[]';
  v_id              bigint;
  v_count           integer;
  v_result          jsonb;
  r                 record;
begin
  -- The rows from the file, one per data line.
  drop table if exists pg_temp.upload_rows;
  create temporary table upload_rows (
    line            integer,
    employee        text,
    employee_code   text,
    project         text,
    project_number  text,
    date_text       text,
    hours_text      text,
    approved        boolean,
    raw             jsonb,
    work_date       date,
    hours           numeric,
    employee_id     bigint,
    project_id      bigint,
    problem         text
  ) on commit drop;

  insert into pg_temp.upload_rows
    (line, employee, employee_code, project, project_number, date_text, hours_text, approved, raw)
  select
    case when x.value ->> 'line' ~ '^\d{1,9}$' then (x.value ->> 'line')::integer else x.ordinality::integer end,
    nullif(btrim(regexp_replace(x.value ->> 'employee', '\s+', ' ', 'g')), ''),
    nullif(btrim(x.value ->> 'employee_code'), ''),
    nullif(btrim(regexp_replace(x.value ->> 'project', '\s+', ' ', 'g')), ''),
    nullif(btrim(x.value ->> 'project_number'), ''),
    nullif(btrim(x.value ->> 'date'), ''),
    nullif(btrim(x.value ->> 'hours'), ''),
    case when jsonb_typeof(x.value -> 'approved') = 'boolean' then (x.value ->> 'approved')::boolean end,
    case when jsonb_typeof(x.value -> 'raw') = 'object' then x.value -> 'raw' end
  from jsonb_array_elements(p_rows) with ordinality as x(value, ordinality);
  get diagnostics v_rows = row_count;

  update pg_temp.upload_rows
     set work_date = public.upload_date(date_text),
         hours = public.upload_number(hours_text);

  update pg_temp.upload_rows
     set problem = case
       when employee is null then 'No employee name'
       when project is null then 'No project'
       when date_text is null then 'No date'
       when work_date is null then 'Date not recognized: ' || left(date_text, 40)
       when hours_text is null then 'No hours'
       when hours is null then 'Hours not recognized: ' || left(hours_text, 40)
       when hours < 0 then 'Negative hours'
       when hours = 0 then 'Zero hours'
       when hours > 24 then 'More than 24 hours'
     end;

  select count(*), min(work_date), max(work_date)
    into v_ok, v_from, v_to
    from pg_temp.upload_rows
   where problem is null;

  -- Checks that stop the whole file.
  if v_ok = 0 then
    v_problem := 'No rows could be imported. See the skipped rows.';
  elsif v_to - v_from > 400 then
    v_problem := format('The dates run from %s to %s, more than a year apart. Check the date column for typos.',
                        to_char(v_from, 'Mon FMDD, YYYY'), to_char(v_to, 'Mon FMDD, YYYY'));
  else
    select count(*) into v_raken_cards
      from public.time_entries
     where source = 'raken' and deleted_at is null and work_date between v_from and v_to;
    if v_raken_cards > 0 then
      v_problem := format('The Raken sync already has time cards for some of these dates (%s to %s). Uploads are only for dates the sync does not cover.',
                          to_char(v_from, 'Mon FMDD, YYYY'), to_char(v_to, 'Mon FMDD, YYYY'));
    end if;
  end if;

  if v_problem is null then
    insert into public.imports (file_name, uploaded_by, date_from, date_to, rows_in_file)
    values (p_file_name, p_uploaded_by, v_from, v_to, v_rows)
    returning id into v_import_id;

    -- Employees: by employee code when the file has one, otherwise by name.
    -- Rows with a code go first, so rows without one find the same person.
    for r in
      select distinct employee, employee_code
        from pg_temp.upload_rows
       where problem is null
       order by employee_code nulls last, employee
    loop
      if r.employee_code is not null then
        select count(*), min(id) into v_count, v_id
          from public.employees where lower(employee_code) = lower(r.employee_code);
        if v_count = 0 then
          -- Someone with this name but no code yet: the same person; keep the code.
          select count(*), min(id) into v_count, v_id
            from public.employees where employee_code is null and lower(full_name) = lower(r.employee);
          if v_count = 1 then
            update public.employees set employee_code = r.employee_code where id = v_id;
          end if;
        end if;
      else
        select count(*), min(id) into v_count, v_id
          from public.employees where lower(full_name) = lower(r.employee);
      end if;

      if v_count > 1 then
        update pg_temp.upload_rows
           set problem = case when r.employee_code is not null
                              then 'More than one employee has code ' || r.employee_code
                              else 'More than one employee named ' || r.employee || '; add an employee code column' end
         where problem is null and employee = r.employee and employee_code is not distinct from r.employee_code;
        continue;
      end if;
      if v_count = 0 then
        insert into public.employees (full_name, employee_code, source)
        values (r.employee, r.employee_code, 'upload')
        returning id into v_id;
        v_new_employees := v_new_employees || to_jsonb(r.employee);
      end if;
      update pg_temp.upload_rows
         set employee_id = v_id
       where problem is null and employee = r.employee and employee_code is not distinct from r.employee_code;
    end loop;

    -- Projects: by project number when the file has one, otherwise by name.
    for r in
      select distinct project, project_number
        from pg_temp.upload_rows
       where problem is null
       order by project_number nulls last, project
    loop
      if r.project_number is not null then
        select count(*), min(id) into v_count, v_id
          from public.projects where lower(project_number) = lower(r.project_number);
        if v_count = 0 then
          select count(*), min(id) into v_count, v_id
            from public.projects where project_number is null and lower(name) = lower(r.project);
          if v_count = 1 then
            update public.projects set project_number = r.project_number where id = v_id;
          end if;
        end if;
      else
        select count(*), min(id) into v_count, v_id
          from public.projects where lower(name) = lower(r.project);
      end if;

      if v_count > 1 then
        update pg_temp.upload_rows
           set problem = case when r.project_number is not null
                              then 'More than one project has number ' || r.project_number
                              else 'More than one project named ' || r.project || '; add a project number column' end
         where problem is null and project = r.project and project_number is not distinct from r.project_number;
        continue;
      end if;
      if v_count = 0 then
        insert into public.projects (name, project_number, source)
        values (r.project, r.project_number, 'upload')
        returning id into v_id;
        v_new_projects := v_new_projects || to_jsonb(r.project);
      end if;
      update pg_temp.upload_rows
         set project_id = v_id
       where problem is null and project = r.project and project_number is not distinct from r.project_number;
    end loop;

    -- The file replaces earlier uploads for its dates, so nothing counts twice.
    with replaced as (
      update public.time_entries
         set deleted_at = now(), replaced_by = v_import_id
       where source = 'upload'
         and deleted_at is null
         and work_date between v_from and v_to
      returning import_id
    )
    select count(*), coalesce(array_agg(distinct import_id), '{}')
      into v_replaced, v_replaced_ids
      from replaced;

    insert into public.time_entries (employee_id, project_id, work_date, hours, approved, raw, source, import_id)
    select employee_id, project_id, work_date, hours, approved, raw, 'upload', v_import_id
      from pg_temp.upload_rows
     where problem is null;
    get diagnostics v_ok = row_count;

    -- Only this upload has live time cards in its date range now.
    select jsonb_build_object(
             'regular', coalesce(sum(regular_hours), 0),
             'ot', coalesce(sum(ot_hours), 0),
             'total', coalesce(sum(total_hours), 0))
      into v_hours
      from public.daily_project_hours
     where work_date between v_from and v_to;

    select coalesce(jsonb_agg(w.message), '[]') into v_warnings
      from (
        select format('%s has %s hours on %s (all projects together)',
                      employee, trim_scale(sum(hours)), to_char(work_date, 'Mon FMDD, YYYY')) as message
          from pg_temp.upload_rows
         where problem is null
         group by employee, work_date
        having sum(hours) > 24
         order by work_date, employee
         limit 20
      ) w;

    select count(*) into v_count from pg_temp.upload_rows where problem is null and work_date > current_date;
    if v_count > 0 then
      v_warnings := v_warnings || to_jsonb(format('%s rows are dated in the future.', v_count));
    end if;

    if not exists (select 1 from pg_temp.upload_rows where problem is null and approved is not null) then
      v_warnings := v_warnings || to_jsonb('The file has no approval status, so these time cards count as not approved.'::text);
    end if;
  else
    v_ok := 0;
  end if;

  select jsonb_build_object(
    'import_id', v_import_id,
    'file_name', p_file_name,
    'date_from', v_from,
    'date_to', v_to,
    'rows_in_file', v_rows,
    'rows_imported', v_ok,
    'rows_skipped', (select count(*) from pg_temp.upload_rows where problem is not null),
    'skipped', (
      select coalesce(jsonb_agg(jsonb_build_object('line', s.line, 'reason', s.problem) order by s.line), '[]')
        from (select line, problem from pg_temp.upload_rows where problem is not null order by line limit 200) s),
    'skipped_reasons', (
      select coalesce(jsonb_object_agg(s.reason, s.n), '{}')
        from (select regexp_replace(problem, ':.*$', '') as reason, count(*) as n
                from pg_temp.upload_rows where problem is not null group by 1) s),
    'employees', (select count(distinct employee_id) from pg_temp.upload_rows where problem is null),
    'projects', (select count(distinct project_id) from pg_temp.upload_rows where problem is null),
    'new_employees', v_new_employees,
    'new_projects', v_new_projects,
    'cards_replaced', v_replaced,
    'replaced_uploads', (
      select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'file_name', i.file_name, 'uploaded_at', i.uploaded_at) order by i.id), '[]')
        from public.imports i where i.id = any (v_replaced_ids)),
    'hours', v_hours,
    'warnings', v_warnings,
    'problem', v_problem
  ) into v_result;

  if v_import_id is not null then
    update public.imports
       set rows_imported = v_ok,
           rows_skipped = v_rows - v_ok,
           cards_replaced = v_replaced,
           summary = v_result
     where id = v_import_id;
  end if;

  return v_result;
end;
$$;

-- Imports uploaded time cards. p_rows is a JSON array prepared by the upload
-- page, one object per data line of the file:
--   {"line": 7, "employee": "Marcus Reyes", "employee_code": "E1001",
--    "project": "Riverside Medical", "project_number": "24-112",
--    "date": "2026-09-14", "hours": 10, "approved": true, "raw": {...}}
-- Only employee, project, date (yyyy-mm-dd) and hours are required.
--
-- The file replaces earlier uploads for its dates (first to last date), so a
-- corrected file never counts hours twice. Dates that already have time cards
-- from the Raken sync are refused.
--
-- p_dry_run = true (the default) runs the whole import, reports the result and
-- then undoes it, so the preview is exactly what the import would do.
create function public.import_time_cards(
  p_file_name   text,
  p_rows        jsonb,
  p_dry_run     boolean default true,
  p_uploaded_by text default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'p_rows must be a JSON array';
  end if;
  if jsonb_array_length(p_rows) > 50000 then
    raise exception 'The file has % rows; the limit is 50,000. Split it by date.', jsonb_array_length(p_rows);
  end if;

  -- One import at a time, so an employee or project is never created twice.
  perform pg_advisory_xact_lock(hashtext('time_card_import'));

  begin
    v_result := public.import_time_cards_run(
      coalesce(nullif(btrim(p_file_name), ''), 'upload'), p_rows, nullif(btrim(p_uploaded_by), ''));
    if p_dry_run then
      raise exception 'undo-dry-run';
    end if;
  exception
    when raise_exception then
      if sqlerrm <> 'undo-dry-run' then
        raise;
      end if;
  end;

  -- Local variables survive the undo, so the dry-run result is still here.
  return v_result || jsonb_build_object(
    'dry_run', p_dry_run,
    'import_id', case when p_dry_run then null else v_result -> 'import_id' end);
end;
$$;
comment on function public.import_time_cards(text, jsonb, boolean, text) is
  'Imports time cards from an uploaded file. Dry run by default: reports what would happen without saving.';

-- Undoes an upload: its time cards stop counting, and the time cards it
-- replaced count again, except on dates that a later upload or the Raken
-- sync now covers.
create function public.undo_import(p_import_id bigint)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_import    public.imports;
  v_removed   integer;
  v_restored  integer;
begin
  perform pg_advisory_xact_lock(hashtext('time_card_import'));

  select * into v_import from public.imports where id = p_import_id for update;
  if not found then
    raise exception 'Upload % does not exist', p_import_id;
  end if;
  if v_import.undone_at is not null then
    raise exception 'Upload % was already undone', p_import_id;
  end if;

  with removed as (
    update public.time_entries
       set deleted_at = now()
     where import_id = p_import_id and deleted_at is null
    returning 1
  )
  select count(*) into v_removed from removed;

  with restored as (
    update public.time_entries t
       set deleted_at = null, replaced_by = null
      from public.imports i
     where t.replaced_by = p_import_id
       and i.id = t.import_id
       and i.undone_at is null
       and not exists (
             select 1 from public.imports later
              where later.id > p_import_id
                and later.undone_at is null
                and t.work_date between later.date_from and later.date_to)
       and not exists (
             select 1 from public.time_entries s
              where s.source = 'raken' and s.deleted_at is null and s.work_date = t.work_date)
    returning 1
  )
  select count(*) into v_restored from restored;

  update public.imports set undone_at = now() where id = p_import_id;

  return jsonb_build_object('import_id', p_import_id, 'cards_removed', v_removed, 'cards_restored', v_restored);
end;
$$;

-- Upload history for the upload page.
create view public.import_history
with (security_invoker = true)
as
select
  i.id,
  i.file_name,
  i.uploaded_at,
  i.uploaded_by,
  i.date_from,
  i.date_to,
  i.rows_in_file,
  i.rows_imported,
  i.rows_skipped,
  i.cards_replaced,
  i.undone_at,
  count(t.id) filter (where t.deleted_at is null) as cards_active,
  case
    when i.undone_at is not null then 'undone'
    when count(t.id) filter (where t.deleted_at is null) = 0 then 'replaced'
    when count(t.id) filter (where t.deleted_at is null) < i.rows_imported then 'partly replaced'
    else 'active'
  end as status
from public.imports i
left join public.time_entries t on t.import_id = i.id
group by i.id;

-- ---------------------------------------------------------------------------
-- Only the backend (service role) may use these for now
-- ---------------------------------------------------------------------------

revoke all on public.import_history from anon, authenticated;

revoke execute on function public.upload_date(text) from public, anon, authenticated;
revoke execute on function public.upload_number(text) from public, anon, authenticated;
revoke execute on function public.import_time_cards_run(text, jsonb, text) from public, anon, authenticated;
revoke execute on function public.import_time_cards(text, jsonb, boolean, text) from public, anon, authenticated;
revoke execute on function public.undo_import(bigint) from public, anon, authenticated;

grant execute on function public.upload_date(text) to service_role;
grant execute on function public.upload_number(text) to service_role;
grant execute on function public.import_time_cards_run(text, jsonb, text) to service_role;
grant execute on function public.import_time_cards(text, jsonb, boolean, text) to service_role;
grant execute on function public.undo_import(bigint) to service_role;
