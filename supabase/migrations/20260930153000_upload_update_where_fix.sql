-- Fix for 20260930150000_time_card_uploads.sql: Supabase's API refuses UPDATE
-- statements without a WHERE clause (even inside functions), so the two
-- updates of the uploaded rows now say "where true". Nothing else changes.
-- Keep a WHERE clause on every UPDATE in functions the API calls.

create or replace function public.import_time_cards_run(p_file_name text, p_rows jsonb, p_uploaded_by text)
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
         hours = public.upload_number(hours_text)
   where true;

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
     end
   where true;

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
