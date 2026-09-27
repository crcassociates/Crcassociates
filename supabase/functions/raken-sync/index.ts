// Copies employees, projects and time cards from Raken into Supabase.
//
// HARD RULE: Raken is READ-ONLY. This function only reads from Raken (GET
// requests through RakenClient) and writes to this project's own tables.
//
// POST /raken-sync with a JSON body:
//   {}                  Time cards changed since the last run. Works without a key
//                       (for the schedule), but at most once per 50 minutes.
//   {"force": true}     Same, right away. Service key required.
//   {"mode": "range", "from": "2026-01-01", "to": "2026-01-31"}
//                       Re-read all time cards dated in the range. Service key required.

import type { SupabaseClient } from "@supabase/supabase-js";
import { adminClient, isServiceCaller, json, RakenClient } from "../_shared/raken.ts";

const WINDOW_DAYS = 30; // Raken caps date filters at 31 days
const OVERLAP_MINUTES = 10; // re-read a little before the last run, to miss nothing
const SCHEDULE_GAP = "50 minutes";
const UPSERT_CHUNK = 500;
const DAY_MS = 24 * 60 * 60 * 1000;

type Summary = {
  employees: number;
  projects: number;
  time_cards_saved: number;
  time_cards_deleted: number;
  windows: string[];
  skipped: { uuid?: string; reason: string }[];
  warnings: string[];
};

type IdMaps = { employees: Map<string, number>; projects: Map<string, number> };

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);

  const privileged = isServiceCaller(req);
  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const mode = body.mode === "range" ? "range" : "incremental";
  const force = body.force === true;
  const from = typeof body.from === "string" ? body.from : "";
  const to = typeof body.to === "string" ? body.to : "";

  if ((mode === "range" || force) && !privileged) return json({ error: "Not allowed" }, 401);
  if (mode === "range" && !(isDate(from) && isDate(to) && from <= to)) {
    return json({ error: 'Range mode needs "from" and "to" dates as yyyy-MM-dd, with from <= to.' }, 400);
  }

  const db = adminClient();
  const { data: runId, error: startError } = await db.rpc("raken_sync_start", {
    p_mode: mode,
    p_params: mode === "range" ? { from, to } : { force },
    p_min_interval: mode === "range" || force ? "0 seconds" : SCHEDULE_GAP,
  });
  if (startError) {
    console.error("Could not start sync:", startError.message);
    return json({ status: "error", error: privileged ? startError.message : "Could not start sync" }, 500);
  }
  if (!runId) return json({ status: "skipped", reason: "A sync is running or ran recently." });

  const summary: Summary = {
    employees: 0,
    projects: 0,
    time_cards_saved: 0,
    time_cards_deleted: 0,
    windows: [],
    skipped: [],
    warnings: [],
  };

  try {
    await runSync(db, mode, from, to, summary);
    await finish(db, runId, "success", summary);
    return json(privileged ? { status: "success", run_id: runId, ...summary } : { status: "success" });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("Sync failed:", message);
    await finish(db, runId, "error", summary, message);
    return json(privileged ? { status: "error", run_id: runId, error: message, ...summary } : { status: "error" }, 500);
  }
});

async function runSync(db: SupabaseClient, mode: string, from: string, to: string, s: Summary): Promise<void> {
  const raken = await RakenClient.create(db);

  // Employees and projects: the full list every run, including inactive and
  // deleted ones, so older time cards still find their names.
  const members = await raken.getAll("/members", { statuses: "ACTIVE,INVITED,INACTIVE,DELETED" });
  s.employees = await upsertChunks(db, "employees", dedupe(members.map(toEmployee)));
  const projects = await raken.getAll("/projects", { statuses: "ACTIVE,INACTIVE,DELETED" });
  s.projects = await upsertChunks(db, "projects", dedupe(projects.map(toProject)));

  const ids: IdMaps = { employees: await idMap(db, "employees"), projects: await idMap(db, "projects") };

  if (mode === "range") {
    for (const [a, b] of dateWindows(from, to)) {
      s.windows.push(`${a}..${b}`);
      const cards = await raken.getAll("/timeCards", { fromDate: a, toDate: b });
      await saveCards(db, raken, ids, cards, s);
      await markMissing(db, a, b, cards, s);
    }
    return;
  }

  const since = await lastIncrementalStart(db);
  for (const [a, b] of timeWindows(since, new Date())) {
    const changedSince = isoSeconds(a);
    const changedUntil = isoSeconds(b);
    s.windows.push(`${changedSince}..${changedUntil}`);
    const changed = await raken.getAll("/timeCards", { changedSince, changedUntil });
    await saveCards(db, raken, ids, changed, s);
    const deleted = await raken.getAll("/timeCards", { deletedFrom: changedSince, deletedTo: changedUntil });
    await markDeleted(db, deleted.map((card) => card?.uuid).filter(Boolean), s);
  }
}

// ---------------------------------------------------------------------------
// Mapping Raken records to our tables
// ---------------------------------------------------------------------------

function shortId(uuid: string): string {
  return uuid.slice(0, 8);
}

function toEmployee(m: any) {
  const name = [m.firstName, m.lastName].map((part) => String(part ?? "").trim()).filter(Boolean).join(" ");
  return {
    raken_id: String(m.uuid),
    full_name: name || m.username || m.email || `Unknown worker (${shortId(String(m.uuid))})`,
    employee_code: m.employeeId || null,
    is_active: m.status === "ACTIVE",
    raw: m,
  };
}

function toProject(p: any) {
  return {
    raken_id: String(p.uuid),
    name: p.name || `Unknown project (${shortId(String(p.uuid))})`,
    project_number: p.number || null,
    status: p.status || null,
    raw: p,
  };
}

function cardHours(card: any): number {
  if (card.totalHours !== undefined && card.totalHours !== null) return Number(card.totalHours);
  const entries: any[] = Array.isArray(card.timeEntries) ? card.timeEntries : [];
  return entries.reduce((sum, entry) => sum + Number(entry?.hours ?? 0), 0);
}

async function saveCards(db: SupabaseClient, raken: RakenClient, ids: IdMaps, cards: any[], s: Summary) {
  const rows = new Map<string, Record<string, unknown>>();
  const deletedIds: string[] = [];

  for (const card of cards) {
    if (!card?.uuid) {
      s.skipped.push({ reason: "Time card without an id" });
      continue;
    }
    if (card.deletedAt) {
      deletedIds.push(card.uuid);
      continue;
    }
    const workerUuid = card.worker?.uuid;
    const projectUuid = card.project?.uuid;
    const hours = cardHours(card);
    if (!workerUuid || !projectUuid) {
      s.skipped.push({ uuid: card.uuid, reason: "Missing worker or project" });
      continue;
    }
    if (!isDate(card.date)) {
      s.skipped.push({ uuid: card.uuid, reason: `Invalid date: ${card.date}` });
      continue;
    }
    if (!Number.isFinite(hours) || hours < 0 || hours > 24) {
      s.skipped.push({ uuid: card.uuid, reason: `Hours out of range: ${card.totalHours}` });
      continue;
    }

    rows.set(card.uuid, {
      raken_id: card.uuid,
      employee_id: await ensureId(db, raken, ids.employees, "employees", workerUuid),
      project_id: await ensureId(db, raken, ids.projects, "projects", projectUuid),
      work_date: card.date,
      hours,
      approved: typeof card.approved === "boolean" ? card.approved : null,
      raken_updated_at: card.updatedAt ?? null,
      deleted_at: null,
      raw: card,
    });
  }

  s.time_cards_saved += await upsertChunks(db, "time_entries", [...rows.values()]);
  await markDeleted(db, deletedIds, s);
}

// Finds our id for a Raken worker or project, reading it from Raken if new.
async function ensureId(
  db: SupabaseClient,
  raken: RakenClient,
  map: Map<string, number>,
  table: "employees" | "projects",
  rakenId: string,
): Promise<number> {
  const known = map.get(rakenId);
  if (known) return known;

  let row: Record<string, unknown>;
  try {
    const path = table === "employees" ? "/members/" : "/projects/";
    const record = await raken.get(path + encodeURIComponent(rakenId));
    row = table === "employees" ? toEmployee(record) : toProject(record);
  } catch (error) {
    const status = (error as { status?: number }).status;
    if (status !== 403 && status !== 404) throw error;
    row = table === "employees"
      ? { raken_id: rakenId, full_name: `Unknown worker (${shortId(rakenId)})`, is_active: false }
      : { raken_id: rakenId, name: `Unknown project (${shortId(rakenId)})` };
  }

  const { data, error } = await db.from(table).upsert(row, { onConflict: "raken_id" }).select("id").single();
  if (error) throw new Error(`Could not save ${table} ${rakenId}: ${error.message}`);
  map.set(rakenId, data.id);
  return data.id;
}

// ---------------------------------------------------------------------------
// Database helpers
// ---------------------------------------------------------------------------

function dedupe<T extends { raken_id: string }>(rows: T[]): T[] {
  return [...new Map(rows.map((row) => [row.raken_id, row])).values()];
}

async function upsertChunks(db: SupabaseClient, table: string, rows: Record<string, unknown>[]): Promise<number> {
  for (let i = 0; i < rows.length; i += UPSERT_CHUNK) {
    const { error } = await db.from(table).upsert(rows.slice(i, i + UPSERT_CHUNK), { onConflict: "raken_id" });
    if (error) throw new Error(`Could not save ${table}: ${error.message}`);
  }
  return rows.length;
}

async function idMap(db: SupabaseClient, table: string): Promise<Map<string, number>> {
  const map = new Map<string, number>();
  const size = 1000;
  for (let start = 0; ; start += size) {
    const { data, error } = await db.from(table).select("id, raken_id").order("id").range(start, start + size - 1);
    if (error) throw new Error(`Could not read ${table}: ${error.message}`);
    for (const row of data ?? []) map.set(row.raken_id, row.id);
    if (!data || data.length < size) break;
  }
  return map;
}

async function markDeleted(db: SupabaseClient, rakenIds: string[], s: Summary): Promise<void> {
  if (rakenIds.length === 0) return;
  const { data, error } = await db.rpc("raken_mark_deleted", { p_raken_ids: rakenIds });
  if (error) throw new Error(`Could not mark deleted time cards: ${error.message}`);
  s.time_cards_deleted += data ?? 0;
}

// After re-reading a date range, marks stored entries Raken no longer has.
async function markMissing(db: SupabaseClient, from: string, to: string, cards: any[], s: Summary): Promise<void> {
  const seen = cards.filter((card) => card?.uuid && !card.deletedAt).map((card) => card.uuid);
  if (seen.length === 0) {
    // Safety: never treat an empty answer from Raken as "everything was deleted".
    const { count, error } = await db
      .from("time_entries")
      .select("id", { count: "exact", head: true })
      .gte("work_date", from)
      .lte("work_date", to)
      .is("deleted_at", null);
    if (error) throw new Error(`Could not count time entries: ${error.message}`);
    if ((count ?? 0) > 0) {
      s.warnings.push(`Raken returned no time cards for ${from}..${to}, but ${count} are stored. Left unchanged.`);
    }
    return;
  }
  const { data, error } = await db.rpc("raken_mark_missing_deleted", { p_from: from, p_to: to, p_seen: seen });
  if (error) throw new Error(`Could not mark missing time cards: ${error.message}`);
  s.time_cards_deleted += data ?? 0;
}

async function lastIncrementalStart(db: SupabaseClient): Promise<Date> {
  const { data, error } = await db
    .from("sync_runs")
    .select("started_at")
    .eq("status", "success")
    .eq("mode", "incremental")
    .order("started_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw new Error(`Could not read sync history: ${error.message}`);
  const base = data ? Date.parse(data.started_at) : Date.now() - 31 * DAY_MS;
  return new Date(base - OVERLAP_MINUTES * 60 * 1000);
}

async function finish(db: SupabaseClient, runId: number, status: string, s: Summary, error?: string) {
  const summary = { ...s, skipped_count: s.skipped.length, skipped: s.skipped.slice(0, 200) };
  const { error: updateError } = await db
    .from("sync_runs")
    .update({ status, finished_at: new Date().toISOString(), summary, error: error ?? null })
    .eq("id", runId);
  if (updateError) console.error("Could not record sync result:", updateError.message);
}

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

function isDate(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(Date.parse(value));
}

function ymd(date: Date): string {
  return date.toISOString().slice(0, 10);
}

function isoSeconds(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

// Splits work dates into windows of at most WINDOW_DAYS days (inclusive).
function dateWindows(from: string, to: string): [string, string][] {
  const windows: [string, string][] = [];
  const end = Date.parse(`${to}T00:00:00Z`);
  for (let start = Date.parse(`${from}T00:00:00Z`); start <= end; ) {
    const stop = Math.min(start + (WINDOW_DAYS - 1) * DAY_MS, end);
    windows.push([ymd(new Date(start)), ymd(new Date(stop))]);
    start = stop + DAY_MS;
  }
  return windows;
}

// Splits a time span into windows of at most WINDOW_DAYS days.
function timeWindows(from: Date, to: Date): [Date, Date][] {
  const windows: [Date, Date][] = [];
  for (let start = from.getTime(); start < to.getTime(); ) {
    const stop = Math.min(start + WINDOW_DAYS * DAY_MS, to.getTime());
    windows.push([new Date(start), new Date(stop)]);
    start = stop;
  }
  return windows;
}
