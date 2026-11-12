// Dispatch: the load board of the dispatch service, as the signed-in user,
// under one of their role assignments. Ported from src/lib/panels/Dispatch.svelte.
//
// Hostless: nothing here touches SSH hosts, so requiresHosts is false and the
// panel works on a machine with an empty host list.
//
// Writes keep the Svelte version's contract exactly (formal/DISPATCH_OPERATIONS_SAFETY.md):
//   - every non-GET call carries a fresh crypto.randomUUID() idempotency key,
//     minted once per user action; the backend replays that same key on its own
//     retries, and a second click is a second request with a second key;
//   - every call carries the selected role assignment id (or none if unset);
//   - load edits and trip transitions send `expected_version` from the row the
//     user acted on, for optimistic concurrency.

import { dispatchRequest, dispatchSignIn, dispatchSignOut, dispatchStatus } from "../lib/api.js";
import { esc, store } from "../lib/dom.js";

export const ROLE_KEY = "dispatch.roleAssignmentId";
export const STATUSES = ["DRAFT", "TENDERED", "BOOKED", "IN_TRANSIT", "DELIVERED", "CANCELLED"];
export const REFRESH_MS = 20_000;
const CLOSED = ["DELIVERED", "CANCELLED"];

// --- Pure logic (tested in dispatch.test.js) ----------------------------------

export const blankStop = () => ({
  kind: "PICKUP", address_text: "", window_start: "", window_end: "", contact_name: "", contact_phone_e164: "",
});
export const blankTrip = () => ({ operator_participant_id: "", vehicle_id: "", trailer_id: "", starts_at: "" });
export const blankLoad = () => ({ external_reference: "", commodity_text: "" });

export const blank = (s) => (String(s ?? "").trim() === "" ? null : String(s).trim());
export const iso = (local) => (local ? new Date(local).toISOString() : null);

/** A refusal as one readable line: the problem's detail and code, else the HTTP status. */
export function problem(body, status) {
  const p = body;
  return p?.detail ? `${p.detail}${p.code ? ` (${p.code})` : ""}` : `HTTP ${status}`;
}

/** Idempotency key for one call: none for reads, a fresh UUID for every write. */
export const idempotencyKeyFor = (method, uuid = () => crypto.randomUUID()) =>
  method === "GET" ? undefined : uuid();

/** The options dispatchRequest gets for one call. */
export function requestOptions(method, body, role, uuid) {
  return {
    body,
    roleAssignmentId: role || undefined,
    // A fresh key per user action: a retry inside the backend replays it,
    // a second click is a second request.
    idempotencyKey: idempotencyKeyFor(method, uuid),
  };
}

/**
 * One call to /v1 as the selected role; throws a readable message on refusal.
 * deps: { request(method, path, opts), getRole(), onUnauthorized(), uuid? }
 */
export function makeApi({ request, getRole, onUnauthorized, uuid }) {
  return async (method, path, body) => {
    const reply = await request(method, path, requestOptions(method, body, getRole(), uuid));
    if (reply.status === 401) {
      await onUnauthorized();
      throw new Error("Signed out. Sign in again.");
    }
    if (reply.status >= 400) throw new Error(problem(reply.body, reply.status));
    return reply.body;
  };
}

/** After listing roles: keep the remembered one if still held, else the only one, else none. */
export const pickRole = (roles, role) =>
  roles.some((r) => r.id === role) ? role : roles.length === 1 ? roles[0].id : "";

export function filterLoads(loads, filter, q) {
  const needle = String(q ?? "").trim().toLowerCase();
  return loads
    .filter((l) => filter === "all" || !CLOSED.includes(l.status))
    .filter(
      (l) =>
        !needle ||
        [l.external_reference, l.commodity_text, ...l.stops.map((s) => s.address_text)]
          .some((t) => t?.toLowerCase().includes(needle)),
    );
}

/** Put a returned load in place, or at the top if it is new. Returns a new array. */
export function upsertLoad(loads, load) {
  const i = loads.findIndex((l) => l.load_id === load.load_id);
  if (i < 0) return [load, ...loads];
  const next = loads.slice();
  next[i] = load;
  return next;
}

// Request builders: method, path and body of each write, exactly as the Svelte panel sent them.

export const createLoadRequest = (form) => ({
  method: "POST",
  path: "/v1/operations/loads",
  body: { external_reference: blank(form.external_reference), commodity_text: blank(form.commodity_text) },
});

export const saveLoadRequest = (load, edit) => ({
  method: "PATCH",
  path: `/v1/operations/loads/${load.load_id}`,
  body: {
    external_reference: blank(edit.external_reference),
    commodity_text: blank(edit.commodity_text),
    expected_version: load.version,
  },
});

export const addStopRequest = (load, s) => ({
  method: "POST",
  path: `/v1/operations/loads/${load.load_id}/stops`,
  body: {
    kind: s.kind,
    address_text: s.address_text.trim(),
    window_start: iso(s.window_start),
    window_end: iso(s.window_end),
    contact_name: blank(s.contact_name),
    contact_phone_e164: blank(s.contact_phone_e164),
  },
});

export const planTripRequest = (load, t) => ({
  method: "POST",
  path: `/v1/operations/loads/${load.load_id}/trips`,
  body: {
    operator_participant_id: t.operator_participant_id,
    vehicle_id: blank(t.vehicle_id),
    trailer_id: blank(t.trailer_id),
    starts_at: iso(t.starts_at),
  },
});

export const transitionRequest = (trip, action) => ({
  method: "POST",
  path: `/v1/operations/trips/${trip.assignment_id}/transitions`,
  body: { action, expected_version: trip.version },
});

/** Which transitions a trip offers: Start when planned, Complete when active, Cancel in either. */
export function tripActions(status) {
  const out = [];
  if (status === "PLANNED") out.push("activate");
  if (status === "ACTIVE") out.push("complete");
  if (status === "PLANNED" || status === "ACTIVE") out.push("cancel");
  return out;
}

/** Only activation runs without asking; complete and cancel end the trip. */
export const needsConfirm = (action) => action !== "activate";

/** The confirmation for complete/cancel, with the request shown verbatim. */
export function transitionAsk(trip, action, driver) {
  return {
    title: `${action === "cancel" ? "Cancel" : "Complete"} ${driver ?? "this driver"}'s trip?`,
    why: "This ends the trip, and with it any location sharing that covered it. It cannot be undone.",
    command: `POST /v1/operations/trips/${trip.assignment_id}/transitions\n{"action": "${action}", "expected_version": ${trip.version}}`,
    danger: true,
  };
}

export const tripClass = (s) => (s === "ACTIVE" ? "ok" : s === "CANCELLED" ? "bad" : s === "PLANNED" ? "warn" : "");
export const loadClass = (s) => (s === "IN_TRANSIT" ? "ok" : s === "CANCELLED" ? "bad" : s === "DRAFT" ? "" : "warn");
export const loadStatusText = (s) => s.replace("_", " ").toLowerCase();
export const activeTrip = (l) => l.trips.find((t) => t.status === "ACTIVE") ?? l.trips.find((t) => t.status === "PLANNED");

export function routeText(l) {
  if (!l.stops.length) return "no stops";
  const first = l.stops[0].address_text;
  return l.stops.length > 1 ? `${first} → ${l.stops[l.stops.length - 1].address_text}` : first;
}

/** Tile meta: "12 loads · 3 active trips", or the state that stands in for it. */
export function summary({ status, role, loads }) {
  if (!status) return "";
  if (!status.api) return "not configured";
  if (!status.signedIn) return "signed out";
  if (!role) return "no role";
  const active = loads.reduce((n, l) => n + l.trips.filter((t) => t.status === "ACTIVE").length, 0);
  return `${loads.length} load${loads.length === 1 ? "" : "s"} · ${active} active trip${active === 1 ? "" : "s"}`;
}

export const canAddStop = (busy, s) => !busy && Boolean(s.address_text.trim());
export const canPlanTrip = (busy, t) => !busy && Boolean(t.operator_participant_id);

// --- Panel --------------------------------------------------------------------

const fmt = (t) => (t ? new Date(t).toLocaleString([], { dateStyle: "short", timeStyle: "short" }) : "—");
const errText = (e) => String(e instanceof Error ? e.message : e);

let cssLoaded = false;
function loadCss() {
  if (cssLoaded || typeof document === "undefined") return;
  cssLoaded = true;
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = new URL("./dispatch.css", import.meta.url).href;
  document.head.append(link);
}

function mount(ctx) {
  loadCss();
  const { body, tools } = ctx;

  const s = {
    status: null,
    roles: [],
    role: store.get(ROLE_KEY, "") ?? "",
    loads: [],
    fleet: { drivers: [], vehicles: [], trailers: [] },
    selectedId: null,
    filter: "open",
    q: "",
    busy: false,
    err: null,
    newLoad: blankLoad(),
    edit: null,
    newStop: blankStop(),
    newTrip: blankTrip(),
  };
  let destroyed = false;

  const api = makeApi({
    request: dispatchRequest,
    getRole: () => s.role,
    onUnauthorized: async () => { s.status = await dispatchStatus(); },
  });
  const call = (r) => api(r.method, r.path, r.body);

  const setRole = (id) => {
    s.role = id;
    if (id) store.set(ROLE_KEY, id);
  };
  const driverName = (id) => s.fleet.drivers.find((d) => d.participant_id === id)?.public_name;
  const unitName = (id) => [...s.fleet.vehicles, ...s.fleet.trailers].find((u) => u.id === id)?.unit_number;
  const selected = () => s.loads.find((l) => l.load_id === s.selectedId) ?? null;

  async function refresh() {
    if (!s.status?.signedIn) return;
    s.busy = true;
    s.err = null;
    render();
    try {
      const list = await api("GET", "/v1/me/role-assignments");
      s.roles = list.role_assignments;
      setRole(pickRole(s.roles, s.role));
      if (!s.role) {
        s.loads = [];
        return;
      }
      const [board, f] = await Promise.all([
        api("GET", "/v1/operations/loads"),
        api("GET", "/v1/operations/fleet"),
      ]);
      s.loads = board.loads;
      s.fleet = f;
      if (s.selectedId && !s.loads.some((l) => l.load_id === s.selectedId)) s.selectedId = null;
    } catch (e) {
      s.err = errText(e);
    } finally {
      s.busy = false;
      render();
    }
  }

  /** Runs a write and puts the load it returns in place. */
  async function write(run, after) {
    s.busy = true;
    s.err = null;
    render();
    try {
      const load = await run();
      s.loads = upsertLoad(s.loads, load);
      s.selectedId = load.load_id;
      after?.();
    } catch (e) {
      s.err = errText(e);
    } finally {
      s.busy = false;
      render();
    }
  }

  function move(trip, action) {
    const run = () => write(() => call(transitionRequest(trip, action)));
    if (!needsConfirm(action)) return run();
    ctx.confirm({
      ...transitionAsk(trip, action, driverName(trip.operator_participant_id)),
      run: async () => {
        await run();
        if (s.err) throw new Error(s.err);
      },
    });
  }

  async function signIn() {
    s.busy = true;
    s.err = null;
    render();
    try {
      await dispatchSignIn();
      s.status = await dispatchStatus();
      await refresh();
    } catch (e) {
      s.err = String(e);
    } finally {
      s.busy = false;
      render();
    }
  }

  async function signOut() {
    try {
      await dispatchSignOut();
      s.status = await dispatchStatus();
    } catch (e) {
      s.err = String(e);
    }
    s.loads = [];
    s.roles = [];
    s.selectedId = null;
    render();
  }

  // --- Rendering ---------------------------------------------------------------
  // Forms keep their values in `s`, so a re-render (the 20 s refresh, a busy
  // toggle) redraws them as they were; focus and caret are carried over too.

  function preserveFocus(root, draw) {
    const a = document.activeElement;
    const key = a && root.contains(a) ? a.dataset?.f : null;
    let sel = null;
    try { if (key) sel = [a.selectionStart, a.selectionEnd]; } catch { /* not a text field */ }
    draw();
    if (!key) return;
    const el = root.querySelector(`[data-f="${key}"]`);
    if (!el) return;
    el.focus();
    try { if (sel && sel[0] != null) el.setSelectionRange(sel[0], sel[1]); } catch { /* not a text field */ }
  }

  const opt = (value, label, current, extra = "") =>
    `<option value="${esc(value)}"${value === current ? " selected" : ""}${extra}>${esc(label)}</option>`;
  const field = (f, value, attrs = "") => `<input data-f="${f}" value="${esc(value)}" ${attrs}>`;

  function toolsHtml() {
    const st = s.status;
    let out = "";
    if (st?.signedIn && s.roles.length > 1) {
      out += `<select data-f="role" title="Role to act under">${opt("", "Choose a role…", s.role, " disabled")}${
        s.roles.map((r) => opt(r.id, r.label, s.role)).join("")}</select>`;
    }
    if (st?.signedIn && s.role) {
      out += `<span class="dispatch-chips">
        <button class="btn${s.filter === "open" ? " primary" : ""}" data-act="filter" data-v="open">open</button>
        <button class="btn${s.filter === "all" ? " primary" : ""}" data-act="filter" data-v="all">all</button>
      </span>${field("q", s.q, 'type="text" placeholder="Filter…" class="dispatch-q"')}`;
    }
    if (st?.signedIn) {
      out += `<button class="btn" data-act="refresh"${s.busy ? " disabled" : ""}>${s.busy ? "Loading…" : "Refresh"}</button>
        <button class="btn" data-act="signout"${s.busy ? " disabled" : ""}>Sign out</button>`;
    }
    return out;
  }

  function listHtml() {
    const shown = filterLoads(s.loads, s.filter, s.q);
    let out = "";
    if (shown.length === 0) out += `<div class="empty">No ${s.filter === "open" ? "open " : ""}loads.</div>`;
    for (const l of shown) {
      const trip = activeTrip(l);
      out += `<button class="dispatch-load${l.load_id === s.selectedId ? " on" : ""}" data-act="select" data-id="${esc(l.load_id)}">
        <div class="row">
          <strong class="trunc grow">${esc(l.external_reference || l.commodity_text || "Untitled load")}</strong>
          <span class="pill ${loadClass(l.status)}">${esc(loadStatusText(l.status))}</span>
        </div>
        <div class="dispatch-sub trunc">${esc(routeText(l))}</div>
        <div class="dispatch-sub">${trip
          ? `<span class="pill ${tripClass(trip.status)}">${esc(trip.status.toLowerCase())}</span> ${esc(driverName(trip.operator_participant_id) ?? "driver")}`
          : "unplanned"}</div>
      </button>`;
    }
    return out;
  }

  function detailHtml() {
    const l = selected();
    if (!l) return `<div class="empty">Select a load, or create one.</div>`;
    const dis = s.busy ? " disabled" : "";
    const head = `<div class="card">
      <div class="row">
        <h3 class="trunc">${esc(l.external_reference || "Untitled load")}</h3>
        <span class="pill ${loadClass(l.status)}">${esc(loadStatusText(l.status))}</span>
        <span class="grow"></span>
        ${s.edit ? "" : `<button class="btn" data-act="edit">Edit</button>`}
      </div>
      ${s.edit
        ? `<form class="dispatch-grid" data-form="save">
            <label>Reference ${field("edit.external_reference", s.edit.external_reference, 'type="text"')}</label>
            <label>Commodity ${field("edit.commodity_text", s.edit.commodity_text, 'type="text"')}</label>
            <div class="row"><button class="btn go"${dis}>Save</button>
              <button type="button" class="btn" data-act="edit-cancel">Cancel</button></div>
          </form>`
        : `<div class="kv"><span>commodity</span><span>${esc(l.commodity_text || "—")}</span></div>
           <div class="kv"><span>created</span><span>${esc(fmt(l.created_at))}</span></div>
           <div class="kv"><span>load id</span><span class="mono">${esc(l.load_id)}</span></div>`}
    </div>`;

    const ns = s.newStop;
    const stops = `<div class="card">
      <h3>Stops</h3>
      ${l.stops.length === 0 ? `<div class="dispatch-sub">No stops yet.</div>` : ""}
      <ol class="dispatch-stops">${l.stops.map((st) => `<li>
        <span class="pill">${esc(st.kind.toLowerCase())}</span>
        <strong>${esc(st.address_text)}</strong>
        ${st.window_start || st.window_end ? `<span class="dispatch-sub">${esc(fmt(st.window_start))} – ${esc(fmt(st.window_end))}</span>` : ""}
        ${st.contact_name || st.contact_phone_e164 ? `<span class="dispatch-sub">${esc(st.contact_name ?? "")} ${esc(st.contact_phone_e164 ?? "")}</span>` : ""}
      </li>`).join("")}</ol>
      <form class="dispatch-grid" data-form="stop">
        <label>Kind <select data-f="newStop.kind">${["PICKUP", "DELIVERY", "OTHER"].map((k) => opt(k, k, ns.kind)).join("")}</select></label>
        <label class="wide">Address ${field("newStop.address_text", ns.address_text, 'type="text" required')}</label>
        <label>Window from ${field("newStop.window_start", ns.window_start, 'type="datetime-local"')}</label>
        <label>to ${field("newStop.window_end", ns.window_end, 'type="datetime-local"')}</label>
        <label>Contact ${field("newStop.contact_name", ns.contact_name, 'type="text"')}</label>
        <label>Phone ${field("newStop.contact_phone_e164", ns.contact_phone_e164, 'type="tel" placeholder="+15551234567"')}</label>
        <div class="row"><button class="btn go" data-need="stop"${canAddStop(s.busy, ns) ? "" : " disabled"}>Add stop</button></div>
      </form>
    </div>`;

    const nt = s.newTrip;
    const equip = (v) => `${v.unit_number}${v.plate ? ` · ${v.plate}` : ""}`;
    const trips = `<div class="card">
      <h3>Trips</h3>
      ${l.trips.length === 0 ? `<div class="dispatch-sub">Not planned yet.</div>` : `<table>
        <thead><tr><th>driver</th><th>equipment</th><th>status</th><th>start</th><th>end</th><th></th></tr></thead>
        <tbody>${l.trips.map((t) => `<tr>
          <td>${esc(driverName(t.operator_participant_id) ?? t.operator_participant_id.slice(0, 8))}</td>
          <td class="mono">${esc([t.vehicle_id, t.trailer_id].filter(Boolean).map((id) => unitName(id) ?? "?").join(" + ") || "—")}</td>
          <td><span class="pill ${tripClass(t.status)}">${esc(t.status.toLowerCase())}</span></td>
          <td>${esc(fmt(t.starts_at))}</td>
          <td>${esc(fmt(t.ends_at))}</td>
          <td><div class="row dispatch-actions">${tripActions(t.status).map((a) => {
            const [cls, label] = a === "activate" ? ["btn go", "Start"] : a === "complete" ? ["btn", "Complete"] : ["btn danger", "Cancel"];
            return `<button class="${cls}" data-act="move" data-v="${a}" data-id="${esc(t.assignment_id)}"${dis}>${label}</button>`;
          }).join("")}</div></td>
        </tr>`).join("")}</tbody>
      </table>`}
      <form class="dispatch-grid" data-form="trip">
        <label>Driver <select data-f="newTrip.operator_participant_id" required>${opt("", "Choose…", nt.operator_participant_id, " disabled")}${
          s.fleet.drivers.map((d) => opt(d.participant_id, d.public_name, nt.operator_participant_id)).join("")}</select></label>
        <label>Vehicle <select data-f="newTrip.vehicle_id">${opt("", "none", nt.vehicle_id)}${
          s.fleet.vehicles.map((v) => opt(v.id, equip(v), nt.vehicle_id)).join("")}</select></label>
        <label>Trailer <select data-f="newTrip.trailer_id">${opt("", "none", nt.trailer_id)}${
          s.fleet.trailers.map((v) => opt(v.id, equip(v), nt.trailer_id)).join("")}</select></label>
        <label>Starts ${field("newTrip.starts_at", nt.starts_at, 'type="datetime-local"')}</label>
        <div class="row"><button class="btn go" data-need="trip"${canPlanTrip(s.busy, nt) ? "" : " disabled"}>Plan trip</button></div>
      </form>
      ${s.fleet.drivers.length === 0 ? `<div class="dispatch-sub">No drivers in this organization.</div>` : ""}
    </div>`;

    return head + stops + trips;
  }

  function bodyHtml() {
    const st = s.status;
    const err = s.err ? `<p class="err">${esc(s.err)}</p>` : "";
    if (!st) return err + `<div class="empty">Loading…</div>`;
    if (!st.api) {
      return err + `<div class="empty">
        Dispatch is not configured. Add a <code class="mono">dispatch</code> section to
        <code class="mono">${esc(ctx.info?.configPath ?? "config.json")}</code>:
        <pre class="mono dispatch-pre">${esc(`"dispatch": {
  "api": "http://localhost:4000",
  "auth": "http://127.0.0.1:4001",
  "provider": "dispatcher"
}`)}</pre></div>`;
    }
    if (!st.signedIn) {
      return err + `<div class="empty">
        <p>Sign in to dispatch at <code class="mono">${esc(st.api)}</code>. Your browser opens to finish.</p>
        <button class="btn go" data-act="signin"${s.busy ? " disabled" : ""}>${s.busy ? "Waiting for the browser…" : "Sign in"}</button>
      </div>`;
    }
    if (!s.role) {
      return err + `<div class="empty">${s.roles.length ? "Choose the role to act under." : "This account holds no dispatch role."}</div>`;
    }
    return err + `<div class="dispatch-board">
      <section class="dispatch-list">
        <form class="card dispatch-new" data-form="load">
          <h3>New load</h3>
          ${field("newLoad.external_reference", s.newLoad.external_reference, 'type="text" placeholder="Reference (PO, BOL…)"')}
          ${field("newLoad.commodity_text", s.newLoad.commodity_text, 'type="text" placeholder="Commodity"')}
          <button class="btn go"${s.busy ? " disabled" : ""}>Create</button>
        </form>
        <div data-r="list" class="dispatch-list">${listHtml()}</div>
      </section>
      <section class="dispatch-detail">${detailHtml()}</section>
    </div>`;
  }

  function render() {
    if (destroyed) return;
    preserveFocus(tools, () => { tools.innerHTML = toolsHtml(); });
    preserveFocus(body, () => { body.innerHTML = bodyHtml(); });
    ctx.setMeta(summary(s));
  }

  function renderList() {
    const list = body.querySelector('[data-r="list"]');
    if (list) list.innerHTML = listHtml();
  }

  function updateNeeds() {
    const stopBtn = body.querySelector('[data-need="stop"]');
    if (stopBtn) stopBtn.disabled = !canAddStop(s.busy, s.newStop);
    const tripBtn = body.querySelector('[data-need="trip"]');
    if (tripBtn) tripBtn.disabled = !canPlanTrip(s.busy, s.newTrip);
  }

  // --- Events (delegated) --------------------------------------------------------

  function onInput(e) {
    const f = e.target?.dataset?.f;
    if (!f || f === "role") return;
    const v = e.target.value;
    if (f === "q") {
      s.q = v;
      renderList();
      return;
    }
    const [obj, key] = f.split(".");
    if (s[obj] && key) s[obj][key] = v;
    updateNeeds();
  }

  function onChange(e) {
    if (e.target?.dataset?.f === "role") {
      setRole(e.target.value);
      refresh();
      return;
    }
    onInput(e);
  }

  function onClick(e) {
    const b = e.target.closest?.("[data-act]");
    if (!b || b.disabled) return;
    const act = b.dataset.act;
    if (act === "filter") { s.filter = b.dataset.v; render(); }
    else if (act === "refresh") refresh();
    else if (act === "signout") signOut();
    else if (act === "signin") signIn();
    else if (act === "select") { s.selectedId = b.dataset.id; s.edit = null; render(); }
    else if (act === "edit") {
      const l = selected();
      if (l) { s.edit = { external_reference: l.external_reference ?? "", commodity_text: l.commodity_text ?? "" }; render(); }
    } else if (act === "edit-cancel") { s.edit = null; render(); }
    else if (act === "move") {
      const l = selected();
      const trip = l?.trips.find((t) => t.assignment_id === b.dataset.id);
      if (trip) move(trip, b.dataset.v);
    }
  }

  function onSubmit(e) {
    const form = e.target.closest?.("[data-form]");
    if (!form) return;
    e.preventDefault();
    if (s.busy) return;
    const l = selected();
    switch (form.dataset.form) {
      case "load":
        write(() => call(createLoadRequest(s.newLoad)), () => { s.newLoad = blankLoad(); });
        break;
      case "save":
        if (l && s.edit) write(() => call(saveLoadRequest(l, s.edit)), () => { s.edit = null; });
        break;
      case "stop":
        if (l && canAddStop(s.busy, s.newStop)) {
          const st = s.newStop;
          write(() => call(addStopRequest(l, st)), () => { s.newStop = blankStop(); });
        }
        break;
      case "trip":
        if (l && canPlanTrip(s.busy, s.newTrip)) {
          const t = s.newTrip;
          write(() => call(planTripRequest(l, t)), () => { s.newTrip = blankTrip(); });
        }
        break;
    }
  }

  for (const root of [body, tools]) {
    root.addEventListener("input", onInput);
    root.addEventListener("change", onChange);
    root.addEventListener("click", onClick);
    root.addEventListener("submit", onSubmit);
  }

  render();
  (async () => {
    try {
      s.status = await dispatchStatus();
      render();
      await refresh();
    } catch (e) {
      s.err = String(e);
      render();
    }
  })();
  // The board changes under other dispatchers and drivers; keep it current.
  const timer = setInterval(() => { if (!s.busy) refresh(); }, REFRESH_MS);

  return {
    destroy() {
      destroyed = true;
      clearInterval(timer);
      for (const root of [body, tools]) {
        root.removeEventListener("input", onInput);
        root.removeEventListener("change", onChange);
        root.removeEventListener("click", onClick);
        root.removeEventListener("submit", onSubmit);
      }
      tools.innerHTML = "";
      body.innerHTML = "";
    },
  };
}

export default {
  id: "dispatch",
  label: "Dispatch",
  hint: "Loads, stops and trips",
  icon: "dispatch",
  group: "Business",
  requiresHosts: false,
  mount,
};
