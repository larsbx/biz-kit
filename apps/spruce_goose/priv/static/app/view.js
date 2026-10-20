// The client's copy of a project, or of a chapter for its administrators:
// what the change feed's frames build (docs/architecture/2026-10-19-live-view.md).
// A frame's changes are whole-entity upserts (value null means removed).

export const projectKinds = ["tasks", "suggestions", "delegations", "receipts", "devices", "workflows"];
export const chapterKinds = ["projects", "administrators"];

export const emptyView = (kinds = projectKinds) => Object.fromEntries(kinds.map((k) => [k, {}]));

export function applyFrame(view, frame) {
  const next = Object.fromEntries(Object.entries(view).map(([k, entities]) => [k, { ...entities }]));

  for (const { kind, id, value } of frame.changes) {
    next[kind] ??= {};
    if (value === null) delete next[kind][id];
    else next[kind][id] = value;
  }

  return next;
}

// The kinds a frame changes: what a page re-renders, or re-reads, on it.
export const changedKinds = (frame) => new Set(frame.changes.map((c) => c.kind));

const byKey = (key) => (a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0);
const entries = (entities) => Object.entries(entities).map(([id, value]) => ({ id, ...value }));
const deviceOrder = ["operator", "reviewer", "administrator"];

// This person's devices, as the project's feed carries them: operator
// devices, then reviewer devices, then administrator keys.
export const ownDevices = (view) =>
  entries(view.devices ?? {}).sort(byKey((d) => [deviceOrder.indexOf(d.kind), d.id].join("\u0000")));

// A chapter's projects and administrators, as the chapter's feed carries them.
export const chapterProjects = (chapter) =>
  Object.values(chapter.projects).sort(byKey((p) => [p.tenant_id, p.project_id].join("\u0000")));

export const chapterAdministrators = (chapter) =>
  entries(chapter.administrators)
    .map(({ id, ...k }) => ({ key_id: id, ...k }))
    .sort(byKey((k) => k.key_id));

export const pendingSuggestions = (view) =>
  Object.entries(view.suggestions)
    .filter(([, s]) => s.status === "pending")
    .map(([id, s]) => ({ id, ...s }));

export function describeTiming(timing, locale) {
  if (!timing) return "—";
  const { schedule, due_ms } = timing;
  const at = (ms) => new Date(ms).toLocaleString(locale, { dateStyle: "medium", timeStyle: "short" });
  const parts = [];

  if (schedule?.kind === "timed") parts.push(`${at(schedule.start_ms)} – ${at(schedule.end_ms)}`);
  if (schedule?.kind === "all_day") parts.push(`${schedule.start_date} – ${schedule.end_date} (all day)`);
  if (due_ms != null) parts.push(`due ${at(due_ms)}`);
  return parts.length ? parts.join(", ") : "unscheduled";
}

export const base64url = {
  encode: (bytes) =>
    btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""),
  decode: (text) =>
    Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0)),
};

// -- editing a suggestion's timing (docs/architecture/2026-10-19-amend.md) ----------
//
// The form's fields, as <input> values in the browser's local time: a timed
// schedule as two datetime-local values, an all-day one as first and last day
// (the ledger's end date is the day after the last), and an optional due time.

const pad = (n) => String(n).padStart(2, "0");
const localInput = (ms) => {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
};
const fromLocal = (value) => new Date(value).getTime();
const shiftDay = (date, days) => {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
};

export function timingForm(timing) {
  const s = timing?.schedule;
  return {
    kind: s?.kind ?? "none",
    start: s?.kind === "timed" ? localInput(Number(s.start_ms)) : "",
    end: s?.kind === "timed" ? localInput(Number(s.end_ms)) : "",
    tz: s?.kind === "timed" ? s.tz : null,
    first: s?.kind === "all_day" ? s.start_date : "",
    last: s?.kind === "all_day" ? shiftDay(s.end_date, -1) : "",
    due: timing?.due_ms != null ? localInput(Number(timing.due_ms)) : "",
  };
}

// The timing a form describes, or `{error}`. The schedule and the due time
// are each kept from `original` exactly while their fields are untouched, so
// the inputs' minute precision never rounds a part nobody edited.
export function formTiming(form, original, tz) {
  const was = timingForm(original);
  const untouched = (keys) => original && keys.every((k) => form[k] === was[k]);
  const scheduled = buildSchedule(form, tz);
  if (scheduled.error) return scheduled;

  const schedule = untouched(["kind", "start", "end", "first", "last"]) ? original.schedule : scheduled.schedule;
  const due_ms = untouched(["due"]) ? original.due_ms : form.due ? fromLocal(form.due) : null;
  if (Number.isNaN(due_ms)) return { error: "A date or time is incomplete." };
  return { timing: { schedule, due_ms } };
}

function buildSchedule(form, tz) {
  let schedule = null;
  if (form.kind === "timed") {
    const [start_ms, end_ms] = [fromLocal(form.start), fromLocal(form.end)];
    if (!(start_ms < end_ms)) return { error: "The end must be after the start." };
    schedule = { kind: "timed", start_ms, end_ms, tz: form.tz ?? tz };
  } else if (form.kind === "all_day") {
    if (!form.first || !form.last || form.last < form.first) return { error: "The last day must not be before the first." };
    schedule = { kind: "all_day", start_date: form.first, end_date: shiftDay(form.last, 1) };
  }
  return { schedule };
}

// -- lifecycle (docs/architecture/2026-10-19-lifecycle.md) ---------------------------

// A receipt in the project for this digest, by ID order so the choice is stable.
export const receiptFor = (view, digest) =>
  Object.keys(view.receipts ?? {})
    .sort()
    .find((id) => view.receipts[id].digest === digest);

const short = (digest) => `${digest.slice(0, 12)}…`;

// What a task's next step is for `me` on the device holding `keyId`:
// `{action, label, ...cites}` to sign, `{waiting}` saying what it still needs
// (with `upload: digest` when it is a file this device could store;
// docs/architecture/2026-10-19-uploads.md), `{evidence: criteria, label}`
// when the work's evidence is due (with `refused: review` after a refusal;
// docs/architecture/2026-10-19-execution.md), or null. Queuing, readiness
// and starting need this device's own acknowledgement of the SOP: the
// ledger checks the key, not only the person.
export function nextStep(taskId, view, me, keyId) {
  const t = view.tasks[taskId];
  if (!t) return null;
  if (t.state === "inbox") return { action: "propose", label: "Propose" };
  if (t.state === "in_progress") return executionStep(t);
  if (!["proposed", "queued", "ready"].includes(t.state)) return null;

  const r = t.readiness;
  if (t.state === "proposed" && !t.dod) return { waiting: "a Definition of Done" };
  if (!r) return { waiting: "a readiness definition" };

  const own = r.acknowledgment?.principal_id === me && r.acknowledgment?.key_id === keyId;
  if (!own) {
    const receipt = receiptFor(view, r.sop_digest);
    return receipt
      ? { action: "acknowledge_sop", label: "Acknowledge the SOP", custody_receipt_id: receipt }
      : { waiting: `a stored copy of the SOP (${short(r.sop_digest)})`, upload: r.sop_digest };
  }
  if (t.state === "proposed") return { action: "queue", label: "Queue" };
  if (t.state === "ready") return { action: "start", label: "Start" };

  const unfinished = r.predecessor_ids.filter((id) => view.tasks[id]?.state !== "completed");
  if (unfinished.length) return { waiting: `${unfinished.join(", ")} to complete` };

  const receipts = {};
  for (const [name, digest] of Object.entries(r.artifact_requirements).sort()) {
    const receipt = receiptFor(view, digest);
    if (!receipt) return { waiting: `a stored copy of input “${name}” (${short(digest)})`, upload: digest };
    receipts[name] = receipt;
  }
  return { action: "ready", label: "Mark ready", custody_receipts: receipts };
}

// Under way: evidence for each criterion, a reviewer's decision on it, then
// completion citing the review that accepted it. A new submission clears
// the review, so a review on record is of the current submission.
function executionStep(t) {
  const { criteria, submission, review } = t.dod;
  if (review?.decision === "accept" && review.submission_event_id === submission?.event_id)
    return { action: "complete", label: "Complete", review_event_id: review.event_id };
  if (submission && !review) return { waiting: "a review of the evidence" };
  return {
    evidence: criteria,
    label: submission ? "Submit evidence again…" : "Submit evidence…",
    ...(review ? { refused: review } : {}),
  };
}

// What else a person may do with a task (docs/architecture/2026-10-19-cancel-reopen.md):
// call it off before the work starts, or send work under way back to queued.
// Each asks for a reason, recorded on the ledger.
export function otherSteps(taskId, view) {
  const state = view.tasks[taskId]?.state;
  if (["inbox", "proposed", "queued", "ready"].includes(state))
    return [{ action: "cancel", label: "Cancel…", question: "Why cancel this task? The reason is recorded on the ledger, and cancelling is final." }];
  if (state === "in_progress")
    return [{ action: "reopen", label: "Send back…", question: "Why send this task back to queued? Its evidence and review are cleared." }];
  return [];
}

// -- administration (docs/architecture/2026-10-19-administration.md) ----------------

// The exact command approving an enrolment request (`GET /api/v1/enrolments/:code`
// as `details`): an operator or reviewer grant for the device, or a governance
// key declared for the person. An administrator signs only that.
export function grantFor(details) {
  const pubkey = { __bytes__: Array.from(base64url.decode(details.public_key), (b) => b.toString(16).padStart(2, "0")).join("") };
  if (details.role === "governance")
    return {
      type: "RoleKeyDeclared",
      payload: { role: "governance", key_id: details.key_id, pubkey, member_id: details.principal_id },
    };
  return {
    type: details.role === "reviewer" ? "TaskReviewerGrantedV1" : "TaskOperatorGrantedV1",
    payload: {
      tenant_id: details.tenant_id,
      project_id: details.project_id,
      principal_id: details.principal_id,
      key_id: details.key_id,
      pubkey,
      device_label: details.label,
    },
  };
}

// What an administrator may end of what a person holds in a project
// (`GET /api/v1/principals/:id`): device and reviewer grants, one by one.
export const revocable = (held) => held.filter((h) => h.kind === "operator" || h.kind === "reviewer");

export const revocationType = (kind) => (kind === "reviewer" ? "TaskReviewerRevokedV1" : "TaskOperatorRevokedV1");

// -- a chapter's projects (docs/architecture/2026-10-19-chapter-projects.md) -----------

const finished = ["completed", "cancelled"];

// A project's tasks by state ({state: count}), in words.
export function taskSummary(tasks) {
  const count = (states) => states.reduce((n, s) => n + (tasks[s] ?? 0), 0);
  const open = count(Object.keys(tasks).filter((s) => !finished.includes(s)));
  const parts = [
    [open, "open"],
    ...finished.map((s) => [count([s]), s]),
  ].filter(([n]) => n > 0);
  return parts.length ? parts.map(([n, s]) => `${n} ${s}`).join(", ") : "no tasks";
}

// This page's query (`location.search`), for another project of the chapter.
export function projectSearch(search, tenant, project) {
  const params = new URLSearchParams(search);
  params.set("tenant", tenant);
  params.set("project", project);
  return `?${params}`;
}

// What a person holds per project (`GET /api/v1/principals/:id`), in this
// page's chapter only: the project open here first, marked `here`.
export const projectsHeld = (found, [chapter, tenant, project]) =>
  found.projects
    .filter((p) => p.chapter_id === chapter)
    .map((p) => ({ ...p, here: p.tenant_id === tenant && p.project_id === project }))
    .sort((a, b) => b.here - a.here);

// Offboarding `found` (`GET /api/v1/principals/:id`) from a whole chapter
// (docs/architecture/2026-10-19-chapter-offboarding.md): each project they
// hold something in, and each of their administrator keys there.
export const chapterOffboarding = (found, chapter) => [
  ...found.projects
    .filter((p) => p.chapter_id === chapter)
    .map((p) => ({
      type: "TaskPrincipalOffboardedV1",
      payload: { tenant_id: p.tenant_id, project_id: p.project_id, principal_id: found.principal_id },
    })),
  ...found.keys
    .filter((k) => k.chapter_id === chapter)
    .map((k) => ({ type: "RoleKeyRevoked", payload: { role: "governance", key_id: k.key_id } })),
];

// -- own devices (docs/architecture/2026-10-19-own-devices.md) ------------------------

// The command this browser signs to revoke one of its person's devices `d`
// ({id, kind}), by the role it signs in: as an operator device if it is one,
// else as a reviewer device, else as an administrator; null if none. An
// administrator key is revoked only as an administrator (`RoleKeyRevoked`):
// the chapter's keys are derived from its governance history alone. The
// server chooses the same way.
export function ownRevocation({ enrolled, reviewing, governing }, d) {
  if (d.kind === "administrator")
    return governing ? { type: "RoleKeyRevoked", payload: { role: "governance", key_id: d.id } } : null;
  if (enrolled || reviewing)
    return {
      type: enrolled ? "TaskDeviceRevokedV1" : "TaskReviewerDeviceRevokedV1",
      payload: { revoked_grant_event_id: d.id },
    };
  if (!governing) return null;
  return { type: d.kind === "reviewer" ? "TaskReviewerRevokedV1" : "TaskOperatorRevokedV1", payload: { authorization_event_id: d.id } };
}

export const deviceKind = { operator: "decides", reviewer: "reviews", administrator: "administers the chapter" };

// Who called a task off and why, or null.
export const cancelledBecause = (t) =>
  t?.state === "cancelled" && t.cancellation
    ? `Cancelled by ${t.cancellation.principal_id ?? "governance"}: “${t.cancellation.reason}”`
    : null;

// Submissions this person may review: someone else's, not yet reviewed.
export const toReview = (view, me) =>
  Object.entries(view.tasks)
    .filter(([, t]) => t.dod?.submission && !t.dod.review && t.dod.submission.principal_id !== me)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([id, t]) => ({ id, title: t.title ?? id, criteria: t.dod.criteria, submission: t.dod.submission }));

// Suggestions no longer pending (accepted, amended, declined, withdrawn,
// superseded), with who resolved them and why: latest decided first, by the
// resolving event's ID (a ULID, so in time order).
const decidedAt = ([id, s]) => s.resolved_by_event_id ?? id;

export const decidedSuggestions = (view) =>
  Object.entries(view.suggestions)
    .filter(([, s]) => s.status !== "pending")
    .sort((a, b) => decidedAt(b).localeCompare(decidedAt(a)))
    .map(([id, s]) => ({ id, ...s }));

// -- workflows (docs/architecture/2026-10-20-workflow-view.md) ----------------------

// The project's workflows under the blueprints now governing them, by roadmap
// then name.
export const workflows = (view) =>
  entries(view.workflows ?? {}).sort(byKey((w) => `${w.roadmap_name}\u0000${w.name}`));

const runName = /^[a-z0-9][a-z0-9_-]{0,63}$/;

// The tasks a run named `run` would create: `run-<step>` for each step of the
// workflow, each a new, valid task ID. `{ids}` to sign, or `{error}` to say.
export function runTaskIds(workflow, run, tasks) {
  if (!runName.test(run ?? "")) return { error: "a run's name is lowercase letters, digits, - and _" };
  const ids = Object.fromEntries(workflow.definitions.map((d) => [d.id, `${run}-${d.id}`]));
  const taken = Object.values(ids).filter((id) => id in tasks || id.length > 128);
  return taken.length ? { error: `${taken.join(", ")} already exist${taken.length === 1 ? "s" : ""}` } : { ids };
}

// Where a task made by a run came from, for its card: the workflow's name if
// the view still has it, and the step.
export function runOf(t, view) {
  const b = t.blueprint;
  if (!b) return null;
  const key = `${encodeURIComponent(b.roadmap_key)}/${encodeURIComponent(b.workflow_id)}`;
  const name = view.workflows?.[key]?.name ?? b.workflow_id;
  return `From workflow ${name}, step ${b.definition_id}`;
}

// -- run readiness (docs/architecture/2026-10-20-run-readiness.md) -----------------

// The project's workflow runs, newest name last: each run's tasks, and those
// governance can define readiness for now (proposed or queued, none yet).
export function runs(view) {
  const byRun = new Map();
  for (const [id, t] of Object.entries(view.tasks)) {
    const run = t.blueprint?.run_event_id;
    if (!run) continue;
    if (!byRun.has(run)) byRun.set(run, { run_event_id: run, blueprint: t.blueprint, tasks: [] });
    byRun.get(run).tasks.push({ id, ...t });
  }
  return [...byRun.values()]
    .map((r) => {
      const tasks = r.tasks.sort(byKey((t) => t.id));
      const pending = tasks.filter((t) => ["proposed", "queued"].includes(t.state) && !t.readiness);
      const done = tasks.filter((t) => t.state === "completed").length;
      // Its name, as the page made its task IDs: `<run>-<step>`.
      const t = tasks[0];
      const suffix = `-${t.blueprint.definition_id}`;
      const name = t.id.endsWith(suffix) ? t.id.slice(0, -suffix.length) : t.id;
      // A run follows one SOP: the one its tasks were already readied under.
      const sop = tasks.find((x) => x.readiness)?.readiness.sop_digest ?? null;
      return { ...r, name, tasks, pending, done, sop };
    })
    .sort(byKey((r) => r.tasks[0].id));
}

const hex64 = /^[0-9a-f]{64}$/;

// The exact definitions a run's readiness batch must hold: per pending task,
// the blueprint's predecessors and input names, with the digests given
// (`inputs[task][name]`, hex) and the run's SOP. `{commands}` or `{error}`.
export function runReadiness(run, { tenant, project, sop, inputs }) {
  if (!hex64.test(sop ?? "")) return { error: "the SOP needs a SHA-256 digest" };
  const commands = [];
  for (const t of run.pending) {
    const requirements = {};
    for (const name of t.blueprint.artifact_requirements) {
      const digest = inputs[t.id]?.[name];
      if (!hex64.test(digest ?? "")) return { error: `${t.id} needs a SHA-256 digest for “${name}”` };
      requirements[name] = { __bytes__: digest };
    }
    commands.push({
      type: "TaskReadinessDefinedV1",
      payload: {
        tenant_id: tenant,
        project_id: project,
        task_id: t.id,
        expected_version: t.version,
        artifact_requirements: requirements,
        predecessor_ids: t.blueprint.predecessor_ids,
        sop_digest: { __bytes__: sop },
      },
    });
  }
  return commands.length ? { commands } : { error: "no task of this run is waiting for readiness" };
}
