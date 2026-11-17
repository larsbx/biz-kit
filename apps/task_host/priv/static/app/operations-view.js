// Read-only presentation over the server's authorized project snapshots.
// Workspace labels/categories are configuration, never permission grants.

const record = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const terminal = new Set(["completed", "cancelled"]);
const safeSegment = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const states = new Set([
  "inbox",
  "proposed",
  "queued",
  "ready",
  "in_progress",
  "completed",
  "cancelled",
]);

export function validTimeZone(value) {
  if (typeof value !== "string" || !value || value.length > 128) return false;
  try {
    new Intl.DateTimeFormat("en", { timeZone: value }).format(0);
    return true;
  } catch {
    return false;
  }
}

export function scopeKey(workspace) {
  return JSON.stringify([
    workspace.chapter_id,
    workspace.tenant_id,
    workspace.project_id,
  ]);
}

export function validateSnapshot(value) {
  const text = (v, max) =>
    typeof v === "string" && v.trim().length > 0 && v.length <= max;
  if (
    !record(value) ||
    value.schema_version !== 1 ||
    !text(value.title, 120) ||
    !text(value.principal, 256) ||
    !validTimeZone(value.time_zone) ||
    !Array.isArray(value.workspaces) ||
    value.workspaces.length > 32
  ) {
    throw new Error("The operations configuration or response is invalid.");
  }
  const ids = new Set();
  const scopes = new Set();
  for (const w of value.workspaces) {
    if (
      !record(w) ||
      !safeSegment.test(w.id ?? "") ||
      !text(w.label, 120) ||
      !text(w.category, 80) ||
      ![w.chapter_id, w.tenant_id, w.project_id].every(
        (part) => typeof part === "string" && safeSegment.test(part),
      ) ||
      !record(w.view) ||
      !["tasks", "suggestions", "workflows"].every((kind) =>
        record(w.view[kind]),
      ) ||
      (w.knowledge !== undefined && (!record(w.knowledge) ||
        !["pending_count", "approved_count", "rejected_count", "withdrawn_count", "stale_count"].every(
          key => Number.isSafeInteger(w.knowledge[key]) && w.knowledge[key] >= 0,
        ))) ||
      ids.has(w.id) ||
      scopes.has(scopeKey(w))
    ) {
      throw new Error("The operations workspace response is invalid.");
    }
    ids.add(w.id);
    scopes.add(scopeKey(w));
  }
  return value;
}

// Generation fencing is also used on logout, page hiding and failed refreshes.
// An older request can never restore records after a newer decision cleared them.
export class SnapshotState {
  constructor() {
    this.generation = 0;
    this.value = null;
  }
  begin() {
    return ++this.generation;
  }
  current(generation) {
    return generation === this.generation;
  }
  accept(generation, value) {
    if (!this.current(generation)) return false;
    this.value = validateSnapshot(value);
    return true;
  }
  clear() {
    this.generation++;
    this.value = null;
  }
}

function timestamp(value) {
  return Number.isSafeInteger(value) && Math.abs(value) <= 8_640_000_000_000_000
    ? value
    : null;
}

export function dateKey(ms, timeZone) {
  if (timestamp(ms) === null) return null;
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(ms);
  const part = (type) => parts.find((p) => p.type === type)?.value;
  return `${part("year").padStart(4, "0")}-${part("month")}-${part("day")}`;
}

function calendarDate(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value))
    return null;
  const ms = Date.parse(`${value}T00:00:00Z`);
  return Number.isFinite(ms) &&
    new Date(ms).toISOString().slice(0, 10) === value
    ? value
    : null;
}

export function addDays(day, days) {
  return new Date(Date.parse(`${day}T00:00:00Z`) + days * 86_400_000)
    .toISOString()
    .slice(0, 10);
}

function scheduleDays(schedule, timeZone) {
  if (!schedule) return null;
  if (schedule.kind === "all_day") {
    const start = calendarDate(schedule.start_date);
    const end = calendarDate(schedule.end_date);
    // Canonical all-day end_date is EXCLUSIVE, including at month/year edges.
    return start && end && end > start
      ? { start, last: addDays(end, -1) }
      : null;
  }
  if (schedule.kind === "timed") {
    const start = timestamp(schedule.start_ms);
    const end = timestamp(schedule.end_ms);
    return start !== null && end !== null && end > start
      ? { start: dateKey(start, timeZone), last: dateKey(end - 1, timeZone) }
      : null;
  }
  return null;
}

export function timingFacts(task, now, timeZone) {
  const timing = record(task.timing) ? task.timing : {};
  const due = timestamp(timing.due_ms);
  const dueDay = due === null ? null : dateKey(due, timeZone);
  const days = scheduleDays(timing.schedule, timeZone);
  const today = dateKey(now, timeZone);
  const tomorrow = addDays(today, 1);
  const horizon = addDays(today, 7);
  const active = !terminal.has(task.state);
  const invalid =
    (timing.due_ms != null && due === null) ||
    (timing.schedule != null && !days);
  const scheduledToday = !!days && days.start <= today && days.last >= today;
  const scheduledNext =
    !!days && days.start <= horizon && days.last >= tomorrow;
  const overdue = active && due !== null && due < now;
  return {
    active,
    due,
    dueDay,
    days,
    invalid,
    overdue,
    today:
      active &&
      (overdue ||
        dueDay === today ||
        scheduledToday ||
        task.state === "in_progress"),
    upcoming:
      active &&
      ((dueDay !== null && dueDay >= tomorrow && dueDay <= horizon) ||
        scheduledNext),
    unscheduled: active && timing.schedule == null && timing.due_ms == null,
  };
}

export function reviewPending(task) {
  const d = task.dod;
  return (
    !terminal.has(task.state) &&
    !!d?.submission &&
    (!d.review || d.review.submission_event_id !== d.submission.event_id)
  );
}

export function workStage(task) {
  const d = task.dod;
  if (reviewPending(task)) return "Evidence awaiting review";
  if (task.state === "in_progress" && d?.review?.decision === "refuse")
    return "Evidence needs changes";
  if (
    task.state === "in_progress" &&
    d?.review?.decision === "accept" &&
    d.review.submission_event_id === d.submission?.event_id
  )
    return "Evidence review accepted";
  if (["proposed", "queued"].includes(task.state) && !task.readiness)
    return "Readiness definition needed";
  return null;
}

export function lifecycleLabel(state) {
  const labels = {
    inbox: "Inbox",
    proposed: "Proposed",
    queued: "Queued",
    ready: "Ready",
    in_progress: "In progress",
    completed: "Completed",
    cancelled: "Cancelled",
  };
  return labels[state] ?? "Unknown state";
}

export function taskRows(snapshot, now = Date.now()) {
  if (!snapshot) return [];
  return snapshot.workspaces.flatMap((workspace) =>
    Object.entries(workspace.view.tasks)
      .filter(
        ([id, task]) =>
          safeSegment.test(id) && record(task) && states.has(task.state),
      )
      .map(([id, task]) => ({
        id,
        task,
        workspace,
        key: JSON.stringify([scopeKey(workspace), id]),
        timing: timingFacts(task, now, snapshot.time_zone),
        needsReview: reviewPending(task),
        stage: workStage(task),
      })),
  );
}

export function selectRows(
  rows,
  { workspace = "", category = "", query = "", tab = "today" } = {},
) {
  const needle = query.trim().toLocaleLowerCase();
  return rows
    .filter((row) => {
      if (workspace && row.workspace.id !== workspace) return false;
      if (category && row.workspace.category !== category) return false;
      if (
        needle &&
        ![
          row.task.title ?? row.id,
          row.task.description ?? "",
          row.workspace.label,
          row.workspace.category,
        ].some((v) => String(v).toLocaleLowerCase().includes(needle))
      )
        return false;
      if (tab === "today") return row.timing.today;
      if (tab === "upcoming") return row.timing.upcoming;
      if (tab === "review") return row.needsReview;
      if (tab === "unscheduled") return row.timing.unscheduled;
      if (tab === "completed") return terminal.has(row.task.state);
      return row.timing.active;
    })
    .sort(
      (a, b) =>
        Number(b.timing.overdue) - Number(a.timing.overdue) ||
        (a.timing.due ?? Infinity) - (b.timing.due ?? Infinity) ||
        String(a.task.title ?? a.id).localeCompare(
          String(b.task.title ?? b.id),
        ) ||
        a.key.localeCompare(b.key),
    );
}

export function metrics(rows) {
  return {
    today: rows.filter((r) => r.timing.today).length,
    overdue: rows.filter((r) => r.timing.overdue).length,
    review: rows.filter((r) => r.needsReview).length,
    active: rows.filter((r) => r.timing.active).length,
  };
}

export function projectLink(
  workspace,
  { taskId = null, provider = "workos", section = "tasks-heading" } = {},
) {
  const query = new URLSearchParams({
    chapter: workspace.chapter_id,
    tenant: workspace.tenant_id,
    project: workspace.project_id,
    provider,
  });
  if (taskId) query.set("focus", taskId);
  return `/app?${query.toString()}#${encodeURIComponent(section)}`;
}

export function formatInstant(ms, timeZone, options = {}) {
  if (timestamp(ms) === null) return "No date";
  return new Intl.DateTimeFormat(undefined, {
    timeZone,
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    ...options,
  }).format(ms);
}

export function timingLabel(row, timeZone) {
  const parts = [];
  if (row.timing.due !== null)
    parts.push(`Due ${formatInstant(row.timing.due, timeZone)}`);
  const schedule = row.task.timing?.schedule;
  if (row.timing.days && schedule?.kind === "all_day") {
    const { start, last } = row.timing.days;
    parts.push(
      start === last ? `All day · ${start}` : `All day · ${start} to ${last}`,
    );
  } else if (row.timing.days && schedule?.kind === "timed") {
    parts.push(
      `${formatInstant(schedule.start_ms, timeZone)} – ${formatInstant(schedule.end_ms, timeZone)}`,
    );
  }
  if (row.timing.invalid) parts.push("Timing unavailable");
  return parts.join(" · ") || "No schedule or due date";
}

export function workflowRows(snapshot, workspace = "", category = "") {
  if (!snapshot) return [];
  return snapshot.workspaces
    .filter(
      (w) =>
        (!workspace || w.id === workspace) &&
        (!category || w.category === category),
    )
    .flatMap((w) =>
      Object.entries(w.view.workflows)
        .filter(([, workflow]) => record(workflow))
        .map(([id, workflow]) => ({ id, workflow, workspace: w })),
    )
    .sort((a, b) =>
      String(a.workflow.name ?? a.id).localeCompare(
        String(b.workflow.name ?? b.id),
      ),
    );
}
