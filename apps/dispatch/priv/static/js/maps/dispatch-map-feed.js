import { MAX_SNAPSHOT_BYTES, parseSnapshot, SNAPSHOT_TIMEOUT_MS } from "./dispatch-map-model.js";

const SNAPSHOT_PATH = "/ui/operations/locations";
const STREAM_PATH = `${SNAPSHOT_PATH}/stream`;
export const MAX_RECONNECT_ATTEMPTS = 5;

/**
 * One authorized snapshot stream. Any transport gap clears observations before
 * reconnecting. A new authorized GET precedes every new stream; EventSource's
 * implicit, unbounded reconnect loop is never used.
 */
export function createLocationFeed({
  onSnapshot,
  onStatus,
  fetchImpl = globalThis.fetch.bind(globalThis),
  EventSourceImpl = globalThis.EventSource,
  now = Date.now,
  schedule = globalThis.setTimeout,
  cancel = globalThis.clearTimeout
}) {
  let active = false;
  let generation = 0;
  let source = null;
  let request = null;
  let timer = null;
  let watchdog = null;
  let requestTimeout = null;
  let attempts = 0;

  function closeTransport() {
    generation++;
    source?.close();
    source = null;
    request?.abort();
    request = null;
    for (const pending of [timer, watchdog, requestTimeout]) if (pending !== null) cancel(pending);
    timer = watchdog = requestTimeout = null;
  }

  function terminal(status) {
    active = false;
    closeTransport();
    onSnapshot(null);
    onStatus(status);
  }

  function retry(reason) {
    closeTransport();
    onSnapshot(null);
    if (!active) return;
    if (attempts >= MAX_RECONNECT_ATTEMPTS) {
      terminal("disconnected");
      return;
    }
    const delay = 1000 * 2 ** attempts++;
    onStatus(reason === "silent" ? "silent" : "reconnecting");
    timer = schedule(() => { timer = null; void connect(); }, delay);
  }

  function armWatchdog(ownGeneration) {
    if (watchdog !== null) cancel(watchdog);
    watchdog = schedule(() => {
      watchdog = null;
      if (active && generation === ownGeneration) retry("silent");
    }, SNAPSHOT_TIMEOUT_MS);
  }

  function accept(text, ownGeneration, streamed) {
    if (!active || generation !== ownGeneration) return false;
    let snapshot;
    try { snapshot = parseSnapshot(text, now()); }
    catch { terminal("invalid"); return false; }
    if (snapshot.status === "capacity_exceeded") {
      terminal("capacity");
      return false;
    }
    onSnapshot(snapshot);
    onStatus("connected");
    if (streamed) attempts = 0;
    armWatchdog(ownGeneration);
    return true;
  }

  async function connect() {
    if (!active) return;
    const ownGeneration = ++generation;
    request = new AbortController();
    const signal = request.signal;
    requestTimeout = schedule(() => {
      requestTimeout = null;
      if (active && generation === ownGeneration) retry("disconnected");
    }, 15000);
    try {
      const response = await fetchImpl(SNAPSHOT_PATH, {
        headers: { accept: "application/json" },
        credentials: "same-origin", cache: "no-store", redirect: "manual", signal
      });
      if (!active || generation !== ownGeneration) return;
      if (response.redirected || response.type === "opaqueredirect" ||
          (response.status >= 300 && response.status < 400) || [401, 403, 404].includes(response.status)) {
        terminal("unavailable");
        return;
      }
      if (!response.ok) { retry("disconnected"); return; }
      const type = response.headers.get("content-type") || "";
      if (!/^application\/json(?:\s*;|$)/i.test(type) ||
          Number(response.headers.get("content-length")) > MAX_SNAPSHOT_BYTES) {
        terminal("invalid");
        return;
      }
      const text = await response.text();
      if (!active || generation !== ownGeneration) return;
      if (requestTimeout !== null) cancel(requestTimeout);
      requestTimeout = null;
      request = null;
      if (!accept(text, ownGeneration, false)) return;
      source = new EventSourceImpl(STREAM_PATH, { withCredentials: true });
      source.addEventListener("dispatch-locations", event => {
        accept(event.data, ownGeneration, true);
      });
      source.onerror = () => {
        if (active && generation === ownGeneration) retry("disconnected");
      };
    } catch {
      if (active && generation === ownGeneration) retry("disconnected");
    }
  }

  return {
    start() {
      if (active) return;
      active = true;
      attempts = 0;
      onSnapshot(null);
      onStatus("connecting");
      void connect();
    },
    destroy() {
      active = false;
      closeTransport();
      onSnapshot(null);
    }
  };
}
