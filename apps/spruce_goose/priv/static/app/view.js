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
const receiptFor = (view, digest) =>
  Object.keys(view.receipts ?? {})
    .sort()
    .find((id) => view.receipts[id].digest === digest);

const short = (digest) => `${digest.slice(0, 12)}…`;

// What a task's next step is for `me` on the device holding `keyId`:
// `{action, label, ...cites}` to sign, `{waiting}` saying what it still needs
// (with `upload: digest` when it is a file this device could store;
// docs/architecture/2026-10-19-uploads.md), or null. Queuing and readiness need this device's own
// acknowledgement of the SOP: the ledger checks the key, not only the person.
export function nextStep(taskId, view, me, keyId) {
  const t = view.tasks[taskId];
  if (!t) return null;
  if (t.state === "inbox") return { action: "propose", label: "Propose" };
  if (t.state !== "proposed" && t.state !== "queued") return null;

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

// Suggestions no longer pending (accepted, amended, declined, withdrawn,
// superseded), with who resolved them and why: latest decided first, by the
// resolving event's ID (a ULID, so in time order).
const decidedAt = ([id, s]) => s.resolved_by_event_id ?? id;

export const decidedSuggestions = (view) =>
  Object.entries(view.suggestions)
    .filter(([, s]) => s.status !== "pending")
    .sort((a, b) => decidedAt(b).localeCompare(decidedAt(a)))
    .map(([id, s]) => ({ id, ...s }));
