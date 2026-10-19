// The client's copy of a project: what the change feed's frames build.
// A frame's changes are whole-entity upserts (value null would mean removed).

export const emptyView = () => ({ tasks: {}, suggestions: {}, delegations: {} });

export function applyFrame(view, frame) {
  const next = {
    tasks: { ...view.tasks },
    suggestions: { ...view.suggestions },
    delegations: { ...view.delegations },
  };

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

// The timing a form describes, or `{error}`. An unchanged form gives back
// `original` exactly, so editing only the title leaves the timing as suggested.
export function formTiming(form, original, tz) {
  const same = ["kind", "start", "end", "first", "last", "due"].every((k) => form[k] === timingForm(original)[k]);
  if (same && original) return { timing: original };

  let schedule = null;
  if (form.kind === "timed") {
    const [start_ms, end_ms] = [fromLocal(form.start), fromLocal(form.end)];
    if (!(start_ms < end_ms)) return { error: "The end must be after the start." };
    schedule = { kind: "timed", start_ms, end_ms, tz: form.tz ?? tz };
  } else if (form.kind === "all_day") {
    if (!form.first || !form.last || form.last < form.first) return { error: "The last day must not be before the first." };
    schedule = { kind: "all_day", start_date: form.first, end_date: shiftDay(form.last, 1) };
  }

  const due_ms = form.due ? fromLocal(form.due) : null;
  if (Number.isNaN(due_ms) || [schedule?.start_ms, schedule?.end_ms].some(Number.isNaN))
    return { error: "A date or time is incomplete." };
  return { timing: { schedule, due_ms } };
}
