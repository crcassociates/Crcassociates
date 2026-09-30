-- Checks the time card upload: preview, import, replacing an earlier upload,
-- undo, and the checks that stop a file.
--
-- Safe to run on the live database: it uses sample data dated January 2001,
-- compares the results, then undoes everything. Nothing is saved.
--
-- Run:  supabase db query --linked -f supabase/checks/upload_check.sql
-- Every row should say PASS.
--
-- Sample week: Mon 2001-01-01 ... Sun 2001-01-07 (the OT examples again).

do $$
declare
  v_results  jsonb := '[]'::jsonb;
  v_file_a   jsonb;
  v_file_b   jsonb;
  v_res      jsonb;
  v_a        bigint;
  v_b        bigint;
  v_count    bigint;
  v_text     text;
  r          record;
begin
  -- Everything in this inner block is undone by the exception at its end.
  begin
    select jsonb_agg(jsonb_build_object(
             'line', line, 'employee', emp, 'employee_code', code, 'project', proj,
             'project_number', num, 'date', d, 'hours', h, 'approved', true,
             'raw', jsonb_build_object('Worker', emp, 'Hours', h)) order by line)
      into v_file_a
      from (values
        (2,  'Check Worker 1', 'CW1', 'Check Project A', 'PA-1', '2001-01-01', 10::numeric),  -- Mon: A 10 h
        (3,  'Check Worker 1', 'CW1', 'Check Project A', 'PA-1', '2001-01-02', 6),            -- Tue: A 6 h + B 5 h
        (4,  'Check Worker 1', 'CW1', 'Check Project B', 'PB-1', '2001-01-02', 5),
        (5,  'Check Worker 1', 'CW1', 'Check Project A', 'PA-1', '2001-01-03', 9),            -- Wed: A 9 h + B 2 h
        (6,  'Check Worker 1', 'CW1', 'Check Project B', 'PB-1', '2001-01-03', 2),
        (7,  'Check Worker 1', 'CW1', 'Check Project A', 'PA-1', '2001-01-04', 5),            -- Thu: two rows on A
        (8,  'Check Worker 1', 'CW1', 'Check Project A', 'PA-1', '2001-01-04', 4),
        (9,  'Check Worker 1', 'CW1', 'Check Project A', 'PA-1', '2001-01-05', 8),            -- Fri: exactly 8 h
        (10, 'Check Worker 1', 'CW1', 'Check Project A', 'PA-1', '2001-01-06', 5),            -- Sat
        (11, 'Check Worker 1', 'CW1', 'Check Project A', 'PA-1', '2001-01-07', 3),            -- Sun: A 3 h + B 2 h
        (12, 'Check Worker 1', 'CW1', 'Check Project B', 'PB-1', '2001-01-07', 2),
        (13, 'Check Worker 2', null,  'Check Project A', null,   '2001-01-01', 8),            -- no code, no number
        (14, 'Check Worker 2', null,  'Check Project A', null,   null,         8),            -- no date
        (15, 'Check Worker 2', null,  'Check Project A', null,   '2001-01-02', 26),           -- too many hours
        (16, 'Check Worker 2', null,  'Check Project A', null,   '2001-02-30', 8),            -- no such date
        (17, 'Check Worker 2', null,  'Check Project A', null,   '2001-01-03', 0)             -- zero hours
      ) as x(line, emp, code, proj, num, d, h);

    -- 1. Preview: reports the result, saves nothing.
    v_res := public.import_time_cards('check-a.csv', v_file_a, true, 'check');
    for r in
      select * from (values
        (1,  'Preview: rows imported',     '12',                   v_res ->> 'rows_imported'),
        (2,  'Preview: rows skipped',      '4',                    v_res ->> 'rows_skipped'),
        (3,  'Preview: dates',             '2001-01-01..2001-01-07', (v_res ->> 'date_from') || '..' || (v_res ->> 'date_to')),
        (4,  'Preview: Regular / OT / total', '53.00 / 14.00 / 67.00',
             format('%s / %s / %s', (v_res #>> '{hours,regular}')::numeric(8,2), (v_res #>> '{hours,ot}')::numeric(8,2), (v_res #>> '{hours,total}')::numeric(8,2))),
        (5,  'Preview: new employees',     '2',                    (jsonb_array_length(v_res -> 'new_employees'))::text),
        (6,  'Preview: new projects',      '2',                    (jsonb_array_length(v_res -> 'new_projects'))::text),
        (7,  'Preview: skipped reasons',   'Date not recognized=1, More than 24 hours=1, No date=1, Zero hours=1',
             (select string_agg(key || '=' || value, ', ' order by key) from jsonb_each_text(v_res -> 'skipped_reasons'))),
        (8,  'Preview: no problem, dry run', 'true / true',        format('%s / %s', (v_res -> 'problem' = 'null'::jsonb)::text, v_res ->> 'dry_run'))
      ) as x(ord, label, expected, actual)
    loop
      v_results := v_results || jsonb_build_object('check_name', r.label, 'expected', r.expected, 'actual', coalesce(r.actual, 'null'),
                                                   'passed', coalesce(r.actual = r.expected, false));
    end loop;

    select count(*) into v_count from public.employees where full_name like 'Check Worker%';
    v_results := v_results || jsonb_build_object('check_name', 'Preview saves nothing',
      'expected', '0 employees, 0 uploads',
      'actual', format('%s employees, %s uploads', v_count, (select count(*) from public.imports where file_name = 'check-a.csv')),
      'passed', v_count = 0 and not exists (select 1 from public.imports where file_name = 'check-a.csv'));

    -- 2. Import: same numbers, saved.
    v_res := public.import_time_cards('check-a.csv', v_file_a, false, 'check');
    v_a := (v_res ->> 'import_id')::bigint;
    select count(*) into v_count from public.time_entries where import_id = v_a and deleted_at is null;
    v_results := v_results || jsonb_build_object('check_name', 'Import: time cards saved',
      'expected', '12', 'actual', v_count::text, 'passed', v_count = 12);

    for r in
      select x.label, x.expected,
             format('%s / %s / %s', s.regular_hours::numeric(8,2), s.ot_hours::numeric(8,2), s.total_hours::numeric(8,2)) as actual
        from (values
          (1, 'Import: Worker 1, Project A', 'Check Worker 1', 'Check Project A', '38.00 / 12.00 / 50.00'),
          (2, 'Import: Worker 1, Project B', 'Check Worker 1', 'Check Project B', '7.00 / 2.00 / 9.00'),
          (3, 'Import: Worker 2, Project A', 'Check Worker 2', 'Check Project A', '8.00 / 0.00 / 8.00')
        ) as x(ord, label, emp, proj, expected)
        left join public.hours_summary('2001-01-01', '2001-01-07') s
          on s.employee_name = x.emp and s.project_name = x.proj
       order by x.ord
    loop
      v_results := v_results || jsonb_build_object('check_name', r.label, 'expected', r.expected, 'actual', coalesce(r.actual, 'null'),
                                                   'passed', coalesce(r.actual = r.expected, false));
    end loop;

    select count(*) into v_count from public.projects where name = 'Check Project A';
    v_results := v_results || jsonb_build_object('check_name', 'Import: project matched by name when the row has no number',
      'expected', '1 project', 'actual', v_count || ' project(s)', 'passed', v_count = 1);

    -- The Raken range sync never marks uploaded time cards as deleted.
    perform public.raken_mark_missing_deleted('2001-01-01', '2001-01-07', '{}');
    select count(*) into v_count from public.time_entries where import_id = v_a and deleted_at is null;
    v_results := v_results || jsonb_build_object('check_name', 'Raken range sync leaves uploads alone',
      'expected', '12', 'actual', v_count::text, 'passed', v_count = 12);

    -- 3. A corrected file for the same dates replaces the first one.
    select jsonb_agg(e order by (e ->> 'line')::int) into v_file_b
      from (
        select case when e ->> 'line' = '13' then jsonb_set(e, '{hours}', '9') else e end as e
          from jsonb_array_elements(v_file_a) e
         where e ->> 'line' not in ('12', '14', '15', '16', '17')
      ) x;
    v_res := public.import_time_cards('check-b.csv', v_file_b, false, 'check');
    v_b := (v_res ->> 'import_id')::bigint;
    v_results := v_results || jsonb_build_object('check_name', 'Replace: earlier cards replaced',
      'expected', '12 cards, from check-a.csv',
      'actual', format('%s cards, from %s', v_res ->> 'cards_replaced', v_res #>> '{replaced_uploads,0,file_name}'),
      'passed', coalesce(v_res ->> 'cards_replaced' = '12' and v_res #>> '{replaced_uploads,0,file_name}' = 'check-a.csv', false));

    select format('%s / %s / %s', sum(regular_hours)::numeric(8,2), sum(ot_hours)::numeric(8,2), sum(total_hours)::numeric(8,2))
      into v_text from public.hours_summary('2001-01-01', '2001-01-07');
    v_results := v_results || jsonb_build_object('check_name', 'Replace: totals come from the new file only',
      'expected', '53.00 / 13.00 / 66.00', 'actual', v_text, 'passed', v_text = '53.00 / 13.00 / 66.00');

    select string_agg(file_name || '=' || status, ', ' order by id) into v_text
      from public.import_history where id in (v_a, v_b);
    v_results := v_results || jsonb_build_object('check_name', 'Replace: upload history',
      'expected', 'check-a.csv=replaced, check-b.csv=active', 'actual', v_text,
      'passed', v_text = 'check-a.csv=replaced, check-b.csv=active');

    -- 4. Undoing the second upload brings the first one back.
    v_res := public.undo_import(v_b);
    select format('%s / %s / %s', sum(regular_hours)::numeric(8,2), sum(ot_hours)::numeric(8,2), sum(total_hours)::numeric(8,2))
      into v_text from public.hours_summary('2001-01-01', '2001-01-07');
    v_results := v_results || jsonb_build_object('check_name', 'Undo: first upload counts again',
      'expected', '11 removed, 12 restored, 53.00 / 14.00 / 67.00',
      'actual', format('%s removed, %s restored, %s', v_res ->> 'cards_removed', v_res ->> 'cards_restored', v_text),
      'passed', coalesce(v_res ->> 'cards_removed' = '11' and v_res ->> 'cards_restored' = '12' and v_text = '53.00 / 14.00 / 67.00', false));

    select string_agg(file_name || '=' || status, ', ' order by id) into v_text
      from public.import_history where id in (v_a, v_b);
    v_results := v_results || jsonb_build_object('check_name', 'Undo: upload history',
      'expected', 'check-a.csv=active, check-b.csv=undone', 'actual', v_text,
      'passed', v_text = 'check-a.csv=active, check-b.csv=undone');

    -- 5. Two employees with the same name and no code: those rows are skipped.
    insert into public.employees (raken_id, full_name) values ('check-twin-1', 'Check Twin'), ('check-twin-2', 'Check Twin');
    v_res := public.import_time_cards('check-twins.csv',
      '[{"line": 2, "employee": "Check Twin", "project": "Check Project A", "date": "2001-02-05", "hours": 8},
        {"line": 3, "employee": "Check Worker 1", "employee_code": "CW1", "project": "Check Project A", "date": "2001-02-05", "hours": 8}]',
      true);
    v_results := v_results || jsonb_build_object('check_name', 'Same name twice: row skipped, others imported',
      'expected', '1 imported, skipped: More than one employee named Check Twin; add an employee code column',
      'actual', format('%s imported, skipped: %s', v_res ->> 'rows_imported', v_res #>> '{skipped,0,reason}'),
      'passed', coalesce(v_res ->> 'rows_imported' = '1'
                         and v_res #>> '{skipped,0,reason}' = 'More than one employee named Check Twin; add an employee code column', false));

    -- 6. Dates more than a year apart stop the file.
    v_res := public.import_time_cards('check-typo.csv',
      '[{"line": 2, "employee": "Check Worker 1", "project": "Check Project A", "date": "2001-02-05", "hours": 8},
        {"line": 3, "employee": "Check Worker 1", "project": "Check Project A", "date": "2003-02-05", "hours": 8}]',
      true);
    v_results := v_results || jsonb_build_object('check_name', 'Dates a year apart: file stopped',
      'expected', 'stopped, 0 imported',
      'actual', format('%s, %s imported', case when v_res ->> 'problem' like 'The dates run from%' then 'stopped' else 'not stopped' end, v_res ->> 'rows_imported'),
      'passed', coalesce(v_res ->> 'problem' like 'The dates run from%' and v_res ->> 'rows_imported' = '0', false));

    -- 7. Dates that the Raken sync already covers are refused.
    insert into public.projects (raken_id, name) values ('check-raken-project', 'Check Raken Project');
    insert into public.time_entries (raken_id, employee_id, project_id, work_date, hours)
    select 'check-raken-card', (select id from public.employees where raken_id = 'check-twin-1'),
           (select id from public.projects where raken_id = 'check-raken-project'), '2001-01-03', 8;
    v_res := public.import_time_cards('check-a.csv', v_file_a, true);
    v_results := v_results || jsonb_build_object('check_name', 'Dates the Raken sync covers: file stopped',
      'expected', 'stopped, 0 imported',
      'actual', format('%s, %s imported', case when v_res ->> 'problem' like 'The Raken sync already has time cards%' then 'stopped' else 'not stopped' end, v_res ->> 'rows_imported'),
      'passed', coalesce(v_res ->> 'problem' like 'The Raken sync already has time cards%' and v_res ->> 'rows_imported' = '0', false));

    -- 8. Bad input is refused outright.
    begin
      perform public.import_time_cards('bad.csv', '{"not": "a list"}', true);
      v_text := 'accepted';
    exception when raise_exception then
      v_text := 'refused';
    end;
    v_results := v_results || jsonb_build_object('check_name', 'Rows that are not a list: refused',
      'expected', 'refused', 'actual', v_text, 'passed', v_text = 'refused');

    raise exception 'undo-check-data';
  exception
    when raise_exception then
      if sqlerrm <> 'undo-check-data' then
        raise;
      end if;
  end;

  -- Local variables survive the undo, so the results are still available here.
  perform set_config('upload_check.results', v_results::text, false);
end;
$$;

select
  r.check_name,
  r.expected,
  r.actual,
  case when r.passed then 'PASS' else 'FAIL' end as result
from jsonb_to_recordset(
       coalesce(nullif(current_setting('upload_check.results', true), ''), '[]')::jsonb
     ) as r(check_name text, expected text, actual text, passed boolean);
