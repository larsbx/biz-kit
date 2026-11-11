import { createLocationFeed } from "./dispatch-map-feed.js";
import { observationPresentation, participantLabel } from "./dispatch-map-model.js";

const MESSAGES = {
  connecting: "Connecting to authorized observations…",
  connected: "Showing the latest authorized observations. Positions are never extrapolated.",
  reconnecting: "Connection lost. Locations cleared; reconnecting…",
  silent: "The observation stream stopped responding. Locations cleared; reconnecting…",
  disconnected: "Connection unavailable. Locations cleared. Reload the page to reconnect.",
  unavailable: "Location access is unavailable. All locations have been cleared.",
  invalid: "The observation response could not be trusted. All locations have been cleared.",
  capacity: "This scope exceeds the 200-participant map limit. No partial map is shown."
};

/** Mount in the server-owned page shell; no domain commands or browser storage. */
export function mountDispatchMap(document = globalThis.document) {
  const host = document.getElementById("dispatch-map");
  if (!host) return null;
  const container = document.getElementById("dispatch-map-globe");
  const credits = document.getElementById("dispatch-map-credits");
  const status = document.getElementById("dispatch-map-status");
  const list = document.getElementById("dispatch-map-participants");
  const fitButton = document.getElementById("dispatch-map-fit");
  if (![container, credits, status, list, fitButton].every(Boolean)) return null;
  let snapshot = null;
  let globe = null;
  let closed = false;
  let feedStatus = "connecting";
  let rendererUnavailable = false;

  function renderStatus() {
    const rendererMessage = rendererUnavailable
      ? snapshot ? " The globe is unavailable; authorized observations remain in the list." : " The globe renderer is unavailable."
      : "";
    status.textContent = `${MESSAGES[feedStatus] || MESSAGES.invalid}${rendererMessage}`;
  }

  function renderList(now) {
    const items = (snapshot?.participants || []).map(participant => {
      const item = document.createElement("li");
      const name = document.createElement("a");
      name.href = `/operations/participants/${encodeURIComponent(participant.participant_id)}`;
      name.textContent = participantLabel(participant.public_name);
      item.append(name);
      const observation = document.createElement("span");
      observation.className = "dispatch-map-observation";
      observation.textContent = participant.position
        ? observationPresentation(participant.position, now).text
        : "No visible location observation";
      item.append(observation);
      if (participant.position?.accuracy_m > 10000000) {
        const uncertainty = document.createElement("span");
        uncertainty.textContent = "Reported uncertainty exceeds the displayed hemisphere.";
        item.append(uncertainty);
      }
      return item;
    });
    list.replaceChildren(...items);
    if (snapshot && snapshot.participants.length === 0) {
      const empty = document.createElement("li");
      empty.textContent = "No participants are visible in this scope.";
      list.append(empty);
    }
  }

  function refresh() {
    if (closed) return;
    const now = Date.now();
    renderList(now);
    fitButton.disabled = !globe || !snapshot?.participants.some(participant => participant.position);
    if (snapshot) {
      try { globe?.render(snapshot, now); }
      catch {
        globe?.destroy();
        globe = null;
        rendererUnavailable = true;
        fitButton.disabled = true;
        renderStatus();
      }
    } else globe?.clear();
  }

  const feed = createLocationFeed({
    onSnapshot(value) { snapshot = value; refresh(); },
    onStatus(value) { feedStatus = value; renderStatus(); }
  });
  fitButton.disabled = true;
  const fit = () => globe?.fit();
  fitButton.addEventListener("click", fit);
  feed.start();

  // Loading failure does not prevent an authorized textual view, and an
  // asynchronous renderer may never resurrect a snapshot already revoked.
  void import("./dispatch-map-renderer.js").then(({ createGlobeView }) => {
    if (closed) return;
    globe = createGlobeView({ container, creditContainer: credits });
    refresh();
  }).catch(() => {
    if (closed) return;
    rendererUnavailable = true;
    renderStatus();
  });

  const ageTimer = globalThis.setInterval(refresh, 5000);
  const destroy = () => {
    if (closed) return;
    closed = true;
    globalThis.clearInterval(ageTimer);
    feed.destroy();
    snapshot = null;
    list.replaceChildren();
    globe?.destroy();
    globe = null;
    fitButton.disabled = true;
    status.textContent = "Location view closed. Reload to reconnect.";
    fitButton.removeEventListener("click", fit);
    globalThis.removeEventListener("pagehide", destroy);
  };
  globalThis.addEventListener("pagehide", destroy);
  return { destroy };
}

if (globalThis.document) {
  mountDispatchMap();
  // A restored page was deliberately cleared on pagehide. Re-enter through
  // the server and its authorization instead of reviving its old snapshot.
  globalThis.addEventListener("pageshow", event => {
    if (event.persisted) globalThis.location.reload();
  });
}
