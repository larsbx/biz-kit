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
