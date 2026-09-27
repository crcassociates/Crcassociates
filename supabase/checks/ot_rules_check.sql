-- Checks the Regular/OT calculation against the rules in REQUIREMENTS.md.
--
-- Safe to run on the live database: it adds sample data, compares the
-- results, then undoes the sample data. Nothing is saved.
--
-- Run:  supabase db query --linked -f supabase/checks/ot_rules_check.sql
-- Every row should say PASS.
--
-- Sample week: Mon 2026-09-21 ... Sun 2026-09-27.

do $$
declare
  v_results jsonb := '[]'::jsonb;
  v_count   bigint;
  w1 bigint; w2 bigint; pa bigint; pb bigint;
  r record;
begin
  -- Everything in this inner block is undone by the exception at its end.
  begin
    insert into public.employees (raken_id, full_name)
      values ('check-worker-1', 'Check Worker 1') returning id into w1;
    insert into public.employees (raken_id, full_name)
      values ('check-worker-2', 'Check Worker 2') returning id into w2;
    insert into public.projects (raken_id, name)
      values ('check-project-a', 'Check Project A') returning id into pa;
    insert into public.projects (raken_id, name)
      values ('check-project-b', 'Check Project B') returning id into pb;

    insert into public.time_entries (raken_id, employee_id, project_id, work_date, hours) values
      ('check-01', w1, pa, '2026-09-21', 10),  -- Mon: one project, 10 h
      ('check-02', w1, pa, '2026-09-22', 6),   -- Tue: two projects, 11 h total
      ('check-03', w1, pb, '2026-09-22', 5),
      ('check-04', w1, pa, '2026-09-23', 9),   -- Wed: A 9 h + B 2 h
      ('check-05', w1, pb, '2026-09-23', 2),
      ('check-06', w1, pa, '2026-09-24', 5),   -- Thu: two entries on A, 9 h total
      ('check-07', w1, pa, '2026-09-24', 4),
      ('check-08', w1, pa, '2026-09-25', 8),   -- Fri: exactly 8 h
      ('check-09', w1, pa, '2026-09-26', 5),   -- Sat: weekend
      ('check-10', w1, pa, '2026-09-27', 3),   -- Sun: weekend, two projects
      ('check-11', w1, pb, '2026-09-27', 2),
      ('check-12', w2, pa, '2026-09-21', 8);   -- Another worker, same project and day as check-01

    -- Deleted in Raken: must be ignored everywhere.
    insert into public.time_entries (raken_id, employee_id, project_id, work_date, hours, deleted_at)
      values ('check-13', w1, pb, '2026-09-21', 5, now());

    -- Daily results
    for r in
      select x.label, x.exp_reg, x.exp_ot, d.regular_hours as act_reg, d.ot_hours as act_ot
      from (values
        (1,  'Mon: A 10h',             w1, pa, date '2026-09-21', 8::numeric, 2::numeric),
        (2,  'Tue: A 6h (also B)',     w1, pa, date '2026-09-22', 6, 0),
        (3,  'Tue: B 5h (also A)',     w1, pb, date '2026-09-22', 5, 0),
        (4,  'Wed: A 9h (also B)',     w1, pa, date '2026-09-23', 8, 1),
        (5,  'Wed: B 2h (also A)',     w1, pb, date '2026-09-23', 2, 0),
        (6,  'Thu: A 5h + 4h entries', w1, pa, date '2026-09-24', 8, 1),
        (7,  'Fri: A exactly 8h',      w1, pa, date '2026-09-25', 8, 0),
        (8,  'Sat: A 5h',              w1, pa, date '2026-09-26', 0, 5),
        (9,  'Sun: A 3h',              w1, pa, date '2026-09-27', 0, 3),
        (10, 'Sun: B 2h',              w1, pb, date '2026-09-27', 0, 2),
        (11, 'Worker 2, Mon: A 8h',    w2, pa, date '2026-09-21', 8, 0)
      ) as x(ord, label, emp, proj, work_date, exp_reg, exp_ot)
      left join public.daily_project_hours d
        on d.employee_id = x.emp and d.project_id = x.proj and d.work_date = x.work_date
      order by x.ord
    loop
      v_results := v_results || jsonb_build_object(
        'check_name', r.label,
        'expected',   format('%s reg / %s OT', r.exp_reg::numeric(6,2), r.exp_ot::numeric(6,2)),
        'actual',     format('%s reg / %s OT', r.act_reg::numeric(6,2), r.act_ot::numeric(6,2)),
        'passed',     coalesce(r.act_reg = r.exp_reg and r.act_ot = r.exp_ot, false));
    end loop;

    select count(*) into v_count
    from public.daily_project_hours
    where employee_id in (w1, w2);
    v_results := v_results || jsonb_build_object(
      'check_name', 'No extra daily rows',
      'expected',   '11 rows',
      'actual',     v_count || ' rows',
      'passed',     v_count = 11);

    select count(*) into v_count
    from public.daily_project_hours
    where employee_id = w1 and project_id = pb and work_date = '2026-09-21';
    v_results := v_results || jsonb_build_object(
      'check_name', 'Deleted time card is ignored',
      'expected',   '0 rows',
      'actual',     v_count || ' rows',
      'passed',     v_count = 0);

    -- Weekly totals
    for r in
      select x.label, x.exp_reg, x.exp_ot, x.exp_total,
             s.regular_hours as act_reg, s.ot_hours as act_ot, s.total_hours as act_total
      from (values
        (1, 'Week: Worker 1, Project A', w1, pa, 38::numeric, 12::numeric, 50::numeric),
        (2, 'Week: Worker 1, Project B', w1, pb, 7, 2, 9),
        (3, 'Week: Worker 2, Project A', w2, pa, 8, 0, 8)
      ) as x(ord, label, emp, proj, exp_reg, exp_ot, exp_total)
      left join public.hours_summary('2026-09-21', '2026-09-27') s
        on s.employee_id = x.emp and s.project_id = x.proj
      order by x.ord
    loop
      v_results := v_results || jsonb_build_object(
        'check_name', r.label,
        'expected',   format('%s reg / %s OT / %s total',
                             r.exp_reg::numeric(6,2), r.exp_ot::numeric(6,2), r.exp_total::numeric(6,2)),
        'actual',     format('%s reg / %s OT / %s total',
                             r.act_reg::numeric(6,2), r.act_ot::numeric(6,2), r.act_total::numeric(6,2)),
        'passed',     coalesce(r.act_reg = r.exp_reg and r.act_ot = r.exp_ot
                               and r.act_total = r.exp_total, false));
    end loop;

    -- A rule change applies only from its start date; earlier days keep the old rule.
    insert into public.ot_rules (effective_from, daily_ot_threshold, weekend_days, note)
      values ('2026-09-24', 10, '{6,7}', 'check only');

    for r in
      select x.label, x.exp_reg, x.exp_ot, d.regular_hours as act_reg, d.ot_hours as act_ot
      from (values
        (1, 'Rule change to 10h from Thu: Mon A 10h keeps old rule', w1, pa, date '2026-09-21', 8::numeric, 2::numeric),
        (2, 'Rule change to 10h from Thu: Thu A 9h uses new rule',   w1, pa, date '2026-09-24', 9, 0)
      ) as x(ord, label, emp, proj, work_date, exp_reg, exp_ot)
      left join public.daily_project_hours d
        on d.employee_id = x.emp and d.project_id = x.proj and d.work_date = x.work_date
      order by x.ord
    loop
      v_results := v_results || jsonb_build_object(
        'check_name', r.label,
        'expected',   format('%s reg / %s OT', r.exp_reg::numeric(6,2), r.exp_ot::numeric(6,2)),
        'actual',     format('%s reg / %s OT', r.act_reg::numeric(6,2), r.act_ot::numeric(6,2)),
        'passed',     coalesce(r.act_reg = r.exp_reg and r.act_ot = r.exp_ot, false));
    end loop;

    raise exception 'undo-check-data';
  exception
    when raise_exception then
      if sqlerrm <> 'undo-check-data' then
        raise;
      end if;
  end;

  -- Local variables survive the undo, so the results are still available here.
  perform set_config('ot_check.results', v_results::text, false);
end;
$$;

select
  r.check_name,
  r.expected,
  r.actual,
  case when r.passed then 'PASS' else 'FAIL' end as result
from jsonb_to_recordset(
       coalesce(nullif(current_setting('ot_check.results', true), ''), '[]')::jsonb
     ) as r(check_name text, expected text, actual text, passed boolean);
