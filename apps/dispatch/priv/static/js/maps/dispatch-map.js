import { createLocationFeed } from "./dispatch-map-feed.js";
import { createSelectedWork } from "./dispatch-map-work.js";
import { observationPresentation, participantLabel, SHA256 } from "./dispatch-map-model.js";
import { parseCoordinateQuery } from "../../vendor/gods-eye-view/coordinate-parser.js";

const MESSAGES = {
  connecting: "Connecting to authorized observations…",
  connected: "Showing the latest authorized observations. Positions are never extrapolated.",
  reconnecting: "Connection lost. Locations cleared; reconnecting…",
  silent: "The observation stream stopped responding. Locations cleared; reconnecting…",
  disconnected: "Connection unavailable. Locations cleared. Reload the page to reconnect.",
  unavailable: "Location access is unavailable. All locations have been cleared.",
  scope_changed: "Your selected access changed. All locations have been cleared. Reload to enter the current scope.",
  invalid: "The observation response could not be trusted. All locations have been cleared.",
  capacity: "This scope exceeds the map's participant or response size limits. No partial map is shown."
};
const WORK_MESSAGES = {
  none: "", loading: "Checking current access to the work linked to this observation…",
  unavailable: "Linked work is unavailable under your current access.",
  capacity_exceeded: "Linked work exceeds the detail size limit. Open the participant record to review its authorized work.",
  changed: "The observation changed. Linked work will refresh with the next authorized snapshot.",
  ready: "Current record state for the assignment linked to this observation; it does not establish the vehicle's present activity."
};

/** One server-bound workspace; no writes, browser storage or private view URLs. */
export function mountDispatchMap(document = globalThis.document) {
  const host = document.getElementById("dispatch-map");
  if (!host) return null;
  const ids = ["globe", "credits", "status", "participants", "fit", "filter", "location-filter", "coverage",
    "search-form", "search", "search-status", "selection", "selected-name", "selected-observation", "selected-position",
    "selected-source", "selected-record", "follow", "clear", "work-status", "work"];
  const ui = Object.fromEntries(ids.map(id => [id, document.getElementById(`dispatch-map-${id}`)]));
  if (Object.values(ui).some(value => !value)) return null;
  const expectedScopeKey = host.dataset.scopeKey;
  if (!SHA256.test(expectedScopeKey)) { ui.status.textContent = MESSAGES.invalid; return null; }
  let snapshot = null;
  let globe = null;
  let closed = false;
  let feedStatus = "connecting";
  let rendererUnavailable = false;
  let selectedId = null;
  let selectedStopId = null;
  let following = false;
  let selectedWork = null;
  const rows = new Map();
  const cleanups = [];
  const listen = (element, name, callback) => {
    element.addEventListener(name, callback);
    cleanups.push(() => element.removeEventListener(name, callback));
  };
  const textNode = (tag, value) => {
    const node = document.createElement(tag); node.textContent = value; return node;
  };
  const bounded = value => participantLabel(value || "");

  function renderStatus() {
    const rendererMessage = rendererUnavailable
      ? snapshot ? " The globe is unavailable; authorized observations remain in the list." : " The globe renderer is unavailable."
      : "";
    ui.status.textContent = `${MESSAGES[feedStatus] || MESSAGES.invalid}${rendererMessage}`;
  }
  function matches(participant, now) {
    const needle = ui.filter.value.trim().toLocaleLowerCase();
    if (needle && !participant.public_name.toLocaleLowerCase().includes(needle) && !participant.participant_id.includes(needle)) return false;
    const mode = ui["location-filter"].value;
    if (mode === "observed") return participant.position !== null;
    if (mode === "missing") return participant.position === null;
    if (mode === "stale") return !!participant.position && observationPresentation(participant.position, now).label === "STALE";
    return true;
  }
  function visibleParticipants(now) { return (snapshot?.participants || []).filter(participant => matches(participant, now)); }

  function clearSelection() {
    selectedId = selectedStopId = null; following = false;
    void work.select(null, null);
    ui.selection.hidden = true;
    for (const key of ["selected-name", "selected-observation", "selected-position", "selected-source"]) ui[key].textContent = "";
    ui["selected-record"].removeAttribute("href");
    ui.follow.setAttribute("aria-pressed", "false");
    globe?.clearWork();
  }
  function selectParticipant(id) {
    const participant = snapshot?.participants.find(value => value.participant_id === id);
    clearSelection();
    if (participant?.position && matches(participant, Date.now())) {
      selectedId = id;
      void work.select(snapshot, selectedId);
    }
    refresh();
    if (selectedId) globe?.focus(selectedId);
  }
  function selectStop(id) {
    if (!selectedWork?.stops.some(stop => stop.ref.id === id && stop.position)) return;
    selectedStopId = id; following = false;
    globe?.renderWork(selectedWork, selectedStopId);
    globe?.focusStop(id);
    renderSelection(Date.now());
    for (const button of ui.work.querySelectorAll("button[data-stop-id]")) {
      button.setAttribute("aria-pressed", String(button.dataset.stopId === id));
    }
  }
  function renderWork() {
    ui.work.replaceChildren();
    globe?.renderWork(selectedWork, selectedStopId);
    if (!selectedWork || !selectedId) return;
    const value = selectedWork;
    const load = document.createElement("a");
    load.href = value.load.record_href;
    load.textContent = `Open load ${bounded(value.load.external_reference || value.load.ref.id)}`;
    ui.work.append(load, textNode("p", `Load: ${value.load.status} · Assignment: ${value.assignment.status} · Version ${value.assignment.version}`));
    if (value.load.commodity_text) ui.work.append(textNode("p", bounded(value.load.commodity_text)));
    ui.work.append(textNode("p", "Next stop unknown: stop progress is not recorded. The following stops are ordered as planned."));
    ui.work.append(textNode("p", `${value.stop_coverage.returned} of ${value.stop_coverage.total} planned stops shown${value.stop_coverage.complete ? " (complete)" : " (bounded subset)"}.`));
    const stops = document.createElement("ol");
    for (const stop of value.stops) {
      const item = document.createElement("li");
      item.append(textNode("p", `${stop.sequence}. ${stop.kind} · ${bounded(stop.address_text)}`));
      item.append(textNode("p", `Window: ${stop.window_start || "unspecified"} — ${stop.window_end || "unspecified"}`));
      if (stop.position) {
        const button = document.createElement("button");
        button.type = "button"; button.textContent = "View planned stop";
        button.dataset.stopId = stop.ref.id; button.setAttribute("aria-pressed", String(stop.ref.id === selectedStopId));
        button.disabled = !globe;
        button.addEventListener("click", () => selectStop(stop.ref.id));
        item.append(button, textNode("p", `Recorded stop coordinates: ${stop.position.lat.toFixed(5)}°, ${stop.position.lng.toFixed(5)}°.`));
      } else item.append(textNode("p", "Stop coordinates unresolved; no map position has been inferred."));
      const record = document.createElement("a"); record.href = `${value.load.record_href}#stop-${stop.ref.id}`;
      record.textContent = "Open stop in load record"; item.append(record); stops.append(item);
    }
    ui.work.append(stops);
  }
  const work = createSelectedWork({ expectedScopeKey,
    onValue(value) {
      // A stop's camera location belongs to the separately authorized work.
      // Return to the admitted observation before removing that work layer.
      if (!value && selectedStopId && selectedId && !following) globe?.focus(selectedId);
      selectedWork = value; selectedStopId = null; renderWork();
    },
    onStatus(value) { ui["work-status"].textContent = WORK_MESSAGES[value] || WORK_MESSAGES.unavailable; }
  });

  function renderSelection(now) {
    const participant = snapshot?.participants.find(value => value.participant_id === selectedId);
    if (!participant?.position) { ui.selection.hidden = true; return; }
    const fix = participant.position;
    ui.selection.hidden = false;
    ui["selected-name"].textContent = participantLabel(participant.public_name);
    ui["selected-observation"].textContent = observationPresentation(fix, now).text;
    ui["selected-position"].textContent = `Observed coordinates: ${fix.lat.toFixed(5)}°, ${fix.lng.toFixed(5)}°.`;
    ui["selected-source"].textContent = `Source: ${fix.provider || "unspecified"} · Acquired ${fix.occurred_at} · Received ${fix.received_at}`;
    ui["selected-record"].href = `/operations/participants/${participant.participant_id}`;
    ui.follow.disabled = !globe;
    ui.follow.setAttribute("aria-pressed", String(following));
    ui.follow.textContent = following ? "Stop following" : "Follow observation";
  }
  function renderList(now) {
    const permitted = new Set((snapshot?.participants || []).map(participant => participant.participant_id));
    for (const [id, row] of rows) if (!permitted.has(id)) { row.item.remove(); rows.delete(id); }
    ui.participants.querySelector(".dispatch-map-empty")?.remove();
    let index = 0;
    for (const participant of snapshot?.participants || []) {
      let row = rows.get(participant.participant_id);
      if (!row) {
        const item = document.createElement("li");
        const button = document.createElement("button"); button.type = "button";
        button.addEventListener("click", () => selectParticipant(participant.participant_id));
        const link = document.createElement("a"); link.textContent = "Open participant record";
        link.href = `/operations/participants/${participant.participant_id}`;
        const observation = document.createElement("span"); observation.className = "dispatch-map-observation";
        const uncertainty = document.createElement("span");
        item.append(button, observation, uncertainty, link);
        row = { item, button, link, observation, uncertainty }; rows.set(participant.participant_id, row);
      }
      row.button.textContent = participantLabel(participant.public_name);
      row.button.disabled = !participant.position;
      row.button.setAttribute("aria-pressed", String(participant.participant_id === selectedId));
      row.observation.textContent = participant.position ? observationPresentation(participant.position, now).text : "No visible location observation";
      row.uncertainty.textContent = participant.position?.accuracy_m > 10000000 ? "Reported uncertainty exceeds the displayed hemisphere." : "";
      row.uncertainty.hidden = !row.uncertainty.textContent;
      row.item.hidden = !matches(participant, now);
      // Do not move a stable node: an age update must preserve keyboard focus.
      if (ui.participants.children[index] !== row.item) ui.participants.insertBefore(row.item, ui.participants.children[index] || null);
      index++;
    }
    const visible = visibleParticipants(now);
    if (snapshot && visible.length === 0) {
      const empty = textNode("li", snapshot.participants.length ? "No participants match these local filters." : "No participants are visible in this scope.");
      empty.className = "dispatch-map-empty"; ui.participants.append(empty);
    }
    ui.coverage.textContent = snapshot
      ? `${visible.length} of ${snapshot.coverage.total} authorized active participants shown · complete organization snapshot · ${visible.filter(value => value.position).length} visible observations. Filters apply to this snapshot, not the camera viewport.`
      : "No authorized snapshot is available.";
    return visible;
  }
  function refresh() {
    if (closed) return;
    const now = Date.now();
    const visible = renderList(now);
    if (selectedId && !visible.some(value => value.participant_id === selectedId && value.position)) clearSelection();
    renderSelection(now);
    ui.fit.disabled = !globe || !visible.some(value => value.position);
    try {
      if (snapshot) globe?.render({ ...snapshot, participants: visible }, now, { selectedId, following });
      else globe?.clear();
    } catch {
      globe?.destroy(); globe = null; rendererUnavailable = true; following = false;
      ui.fit.disabled = true; renderSelection(now); renderStatus();
    }
  }
  const feed = createLocationFeed({ expectedScopeKey,
    onSnapshot(value) {
      snapshot = value;
      if (!value) {
        clearSelection(); ui.filter.value = ""; ui["location-filter"].value = "all"; ui.search.value = "";
        ui["search-status"].textContent = "Coordinate search runs locally. Place-name search is not configured.";
      } else if (selectedId) {
        const participant = value.participants.find(row => row.participant_id === selectedId);
        if (!participant?.position || !matches(participant, Date.now())) clearSelection();
        else void work.select(value, selectedId);
      }
      refresh();
    },
    onStatus(value) { feedStatus = value; renderStatus(); }
  });
  listen(ui.fit, "click", () => { following = false; refresh(); globe?.fit(); });
  listen(ui.filter, "input", refresh);
  listen(ui["location-filter"], "change", refresh);
  listen(ui.follow, "click", () => { following = !following; refresh(); });
  listen(ui.clear, "click", () => {
    const previous = selectedId; clearSelection(); refresh();
    rows.get(previous)?.button.focus();
  });
  listen(ui["search-form"], "submit", event => {
    event.preventDefault();
    const coordinates = parseCoordinateQuery(ui.search.value);
    if (!coordinates) { ui["search-status"].textContent = "Enter valid decimal latitude and longitude, or a two-dimensional WGS84 geo: URI. No geocoder request was sent."; return; }
    if (!globe || !snapshot) { ui["search-status"].textContent = "The globe is unavailable. Coordinates have not been sent anywhere."; return; }
    clearSelection(); refresh(); globe.showCoordinates(coordinates);
    ui["search-status"].textContent = `Viewing ${coordinates.label}. This changes only the camera.`;
  });
  ui.fit.disabled = true;
  feed.start();
  void import("./dispatch-map-renderer.js").then(({ createGlobeView }) => {
    if (closed) return;
    globe = createGlobeView({ container: ui.globe, creditContainer: ui.credits, onSelect: selectParticipant, onStopSelect: selectStop });
    refresh(); renderWork();
  }).catch(() => { if (!closed) { rendererUnavailable = true; renderStatus(); } });
  const ageTimer = globalThis.setInterval(refresh, 5000);
  const destroy = () => {
    if (closed) return;
    feed.destroy(); clearSelection(); work.destroy();
    snapshot = null; rows.clear(); ui.participants.replaceChildren();
    globe?.destroy(); globe = null; closed = true;
    globalThis.clearInterval(ageTimer);
    ui.fit.disabled = true; ui.status.textContent = "Location view closed. Reload to reconnect.";
    for (const cleanup of cleanups) cleanup();
    globalThis.removeEventListener("pagehide", destroy);
  };
  globalThis.addEventListener("pagehide", destroy);
  return { destroy };
}

if (globalThis.document) {
  mountDispatchMap();
  globalThis.addEventListener("pageshow", event => {
    if (event.persisted) globalThis.location.reload();
  });
}
