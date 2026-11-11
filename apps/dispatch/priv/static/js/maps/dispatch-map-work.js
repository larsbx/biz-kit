import { SHA256, isObject, reference, assertCurrentSnapshot } from "./dispatch-map-model.js";

const MAX_WORK_BYTES = 65536;
const time = value => typeof value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/.test(value) && Number.isFinite(Date.parse(value));
const optionalTime = value => value === null || time(value);
const text = value => typeof value === "string";
const optionalText = value => value === null || text(value);
const version = value => Number.isSafeInteger(value) && value >= 0;
const copyRef = value => ({ kind: value.kind, id: value.id.toLowerCase() });
const optionalRef = (value, kind) => value === null || reference(value, kind);

/** Only current, separately authorized work bound to this exact observation. */
export function validateWork(value, expected, now = Date.now()) {
  if (!isObject(value) || value.schema_version !== 1 || value.status !== "ok" || !time(value.generated_at) ||
      !isObject(value.scope) || value.scope.key !== expected.scope.key ||
      !reference(value.scope.organization, "organization", expected.scope.organization.id) ||
      !reference(value.participant, "participant", expected.participantId) ||
      !reference(value.observation_ref, "location_observation", expected.observationId)) {
    throw new TypeError("Invalid selected work binding");
  }
  assertCurrentSnapshot(value, now);
  const assignment = value.assignment;
  const load = value.load;
  const coverage = value.stop_coverage;
  if (!isObject(assignment) || !reference(assignment.ref, "assignment") || !text(assignment.status) ||
      assignment.status.length > 64 || !version(assignment.version) || !optionalTime(assignment.starts_at) ||
      !optionalTime(assignment.ends_at) || !optionalRef(assignment.vehicle_ref, "vehicle") || !optionalRef(assignment.trailer_ref, "trailer") ||
      !isObject(load) || !reference(load.ref, "load") || !text(load.status) || load.status.length > 64 || !version(load.version) ||
      !optionalText(load.external_reference) || !optionalText(load.commodity_text) ||
      load.record_href !== `/operations/loads/${load.ref.id}` ||
      !Array.isArray(value.stops) || value.stops.length > 200 ||
      !isObject(coverage) || coverage.limit !== 200 || coverage.returned !== value.stops.length ||
      !Number.isSafeInteger(coverage.total) || coverage.total < coverage.returned ||
      typeof coverage.complete !== "boolean" || coverage.complete !== (coverage.total === coverage.returned) ||
      !isObject(value.next_stop) || value.next_stop.status !== "unknown" || value.next_stop.reason !== "stop_progress_not_recorded") {
    throw new TypeError("Invalid selected work");
  }
  const seen = new Set();
  const stops = value.stops.map(stop => {
    if (!isObject(stop) || !reference(stop.ref, "stop") || seen.has(stop.ref.id.toLowerCase()) ||
        !Number.isSafeInteger(stop.sequence) || stop.sequence < 1 || !text(stop.kind) || stop.kind.length > 64 ||
        !text(stop.address_text) || !optionalTime(stop.window_start) || !optionalTime(stop.window_end) ||
        !["recorded", "unresolved"].includes(stop.position_status) ||
        (stop.position_status === "unresolved" ? stop.position !== null :
          !isObject(stop.position) || !Number.isFinite(stop.position.lat) || Math.abs(stop.position.lat) > 90 ||
          !Number.isFinite(stop.position.lng) || Math.abs(stop.position.lng) > 180)) {
      throw new TypeError("Invalid planned stop");
    }
    seen.add(stop.ref.id.toLowerCase());
    return { ref: copyRef(stop.ref), sequence: stop.sequence, kind: stop.kind,
      address_text: stop.address_text, window_start: stop.window_start, window_end: stop.window_end,
      position_status: stop.position_status,
      position: stop.position === null ? null : { lat: stop.position.lat, lng: stop.position.lng } };
  });
  return {
    schema_version: 1, status: "ok", generated_at: value.generated_at,
    scope: { key: value.scope.key, organization: copyRef(value.scope.organization) },
    participant: copyRef(value.participant), observation_ref: copyRef(value.observation_ref),
    assignment: { ref: copyRef(assignment.ref), status: assignment.status, version: assignment.version,
      starts_at: assignment.starts_at, ends_at: assignment.ends_at,
      vehicle_ref: assignment.vehicle_ref && copyRef(assignment.vehicle_ref),
      trailer_ref: assignment.trailer_ref && copyRef(assignment.trailer_ref) },
    load: { ref: copyRef(load.ref), status: load.status, version: load.version,
      external_reference: load.external_reference, commodity_text: load.commodity_text,
      record_href: `/operations/loads/${load.ref.id.toLowerCase()}` },
    stops: stops.sort((a, b) => a.sequence - b.sequence || a.ref.id.localeCompare(b.ref.id)),
    stop_coverage: { complete: coverage.complete, returned: coverage.returned, total: coverage.total, limit: 200 },
    next_stop: { status: "unknown", reason: "stop_progress_not_recorded" }
  };
}

/** Every selection/snapshot cancels and clears before requesting fresh details. */
export function createSelectedWork({ expectedScopeKey, onValue, onStatus,
  fetchImpl = globalThis.fetch.bind(globalThis), now = Date.now,
  schedule = globalThis.setTimeout, cancel = globalThis.clearTimeout }) {
  if (!SHA256.test(expectedScopeKey)) throw new TypeError("A server-bound scope is required");
  let generation = 0;
  let request = null;
  let timer = null;
  let closed = false;

  function clear() {
    generation++;
    request?.abort(); request = null;
    if (timer !== null) cancel(timer);
    timer = null;
    onValue(null);
  }

  async function select(snapshot, participantId) {
    if (closed) return;
    clear();
    const participant = snapshot?.participants.find(value => value.participant_id === participantId);
    if (!participant?.position || snapshot?.scope.key !== expectedScopeKey) { onStatus("none"); return; }
    if (!snapshot.work_access) { onStatus("unavailable"); return; }
    const expected = { scope: snapshot.scope, participantId, observationId: participant.position.observation_ref.id };
    const ownGeneration = generation;
    request = new AbortController();
    const signal = request.signal;
    onStatus("loading");
    timer = schedule(() => {
      if (generation !== ownGeneration || closed) return;
      clear(); onStatus("unavailable");
    }, 15000);
    try {
      const response = await fetchImpl(`/ui/operations/locations/${encodeURIComponent(participantId)}/work`, {
        headers: { accept: "application/json", "x-dispatch-observation": expected.observationId },
        credentials: "same-origin", cache: "no-store", redirect: "manual", signal
      });
      if (closed || generation !== ownGeneration) return;
      if (response.redirected || response.type === "opaqueredirect" || !response.ok) {
        clear(); onStatus(response.status === 409 ? "changed" : response.status === 422 ? "capacity_exceeded" : "unavailable"); return;
      }
      if (!/^application\/json(?:\s*;|$)/i.test(response.headers.get("content-type") || "") ||
          Number(response.headers.get("content-length")) > MAX_WORK_BYTES) throw new TypeError("Invalid work response");
      const body = await response.text();
      if (closed || generation !== ownGeneration) return;
      if (body.length > MAX_WORK_BYTES || new TextEncoder().encode(body).byteLength > MAX_WORK_BYTES) throw new TypeError("Work response too large");
      const value = validateWork(JSON.parse(body), expected, now());
      if (timer !== null) cancel(timer);
      timer = null; request = null;
      onValue(value); onStatus("ready");
    } catch {
      if (closed || generation !== ownGeneration) return;
      clear(); onStatus("unavailable");
    }
  }
  return { select, destroy() { if (closed) return; closed = true; clear(); onStatus("none"); } };
}
