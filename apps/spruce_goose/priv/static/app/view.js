// The client's copy of a project: what the change feed's frames build.
// A frame's changes are whole-entity upserts (value null would mean removed).

const kinds = ["tasks", "suggestions", "delegations", "receipts"];

export const emptyView = () => Object.fromEntries(kinds.map((k) => [k, {}]));

export function applyFrame(view, frame) {
  const next = Object.fromEntries(kinds.map((k) => [k, { ...view[k] }]));

  for (const { kind, id, value } of frame.changes) {
    if (value === null) delete next[kind][id];
    else next[kind][id] = value;
  }

  return next;
}

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

// What an administrator may end of what a person holds in this project
// (`GET /api/v1/principals/:id`): device and reviewer grants, one by one.
export const revocable = (held) => held.filter((h) => h.kind === "operator" || h.kind === "reviewer");

export const revocationType = (kind) => (kind === "reviewer" ? "TaskReviewerRevokedV1" : "TaskOperatorRevokedV1");

// -- own devices (docs/architecture/2026-10-19-own-devices.md) ------------------------

// The command this browser signs to revoke one of its person's devices `d`
// ({id, kind}), by the role it signs in: as an operator device if it is one,
// else as a reviewer device, else as an administrator; null if none. The
// server chooses the same way.
export function ownRevocation({ enrolled, reviewing, governing }, d) {
  if (enrolled || reviewing)
    return {
      type: enrolled ? "TaskDeviceRevokedV1" : "TaskReviewerDeviceRevokedV1",
      payload: d.kind === "administrator" ? { revoked_key_id: d.id } : { revoked_grant_event_id: d.id },
    };
  if (!governing) return null;
  if (d.kind === "administrator") return { type: "RoleKeyRevoked", payload: { role: "governance", key_id: d.id } };
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
