import { freshness } from "./map-freshness.js";

export const MAX_PARTICIPANTS = 200;
export const MAX_SNAPSHOT_BYTES = 262144;
export const SNAPSHOT_TIMEOUT_MS = 45000;
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/;

export const isObject = value => value !== null && typeof value === "object" && !Array.isArray(value);
const numeric = value => typeof value === "number" && Number.isFinite(value);
const time = value => typeof value === "string" && ISO_TIME.test(value) && Number.isFinite(Date.parse(value));

export const SHA256 = /^[0-9a-f]{64}$/;
export const reference = (value, kind, id) => isObject(value) && value.kind === kind &&
  typeof value.id === "string" && UUID.test(value.id) && (!id || value.id.toLowerCase() === id.toLowerCase());
const copyRef = value => ({ kind: value.kind, id: value.id.toLowerCase() });

export function assertCurrentSnapshot(value, now = Date.now()) {
  const generated = Date.parse(value.generated_at);
  if (generated > now + 30000 || now - generated > SNAPSHOT_TIMEOUT_MS) {
    throw new TypeError("Location snapshot is not current");
  }
}

/** Validate one scoped complete replacement; unknown fields never enter the UI. */
export function validateSnapshot(value, now = Date.now(), { requireCurrent = true } = {}) {
  if (!isObject(value) || value.schema_version !== 2 || value.limit !== MAX_PARTICIPANTS ||
      !["ok", "capacity_exceeded"].includes(value.status) || !time(value.generated_at) ||
      !Array.isArray(value.participants) || value.participants.length > MAX_PARTICIPANTS ||
      !isObject(value.scope) || !SHA256.test(value.scope.key) || !reference(value.scope.organization, "organization") ||
      !isObject(value.query) || value.query.area !== "organization" || value.query.time !== "latest" ||
      !isObject(value.coordinates) || value.coordinates.crs !== "EPSG:4326" ||
      value.coordinates.units !== "degrees" || value.coordinates.order !== "named_lat_lng" ||
      !isObject(value.source) || value.source.kind !== "dispatch_location_projection" || !SHA256.test(value.source.revision) ||
      !isObject(value.cursor) || !UUID.test(value.cursor.stream_id) || !Number.isSafeInteger(value.cursor.sequence) || value.cursor.sequence < 0 ||
      typeof value.work_access !== "boolean") {
    throw new TypeError("Invalid location snapshot");
  }
  if (requireCurrent) assertCurrentSnapshot(value, now);
  const generated = Date.parse(value.generated_at);
  const coverage = value.coverage;
  if (!isObject(coverage) || coverage.population !== "active_participants" || coverage.limit !== MAX_PARTICIPANTS ||
      coverage.next_cursor !== null || coverage.returned !== value.participants.length ||
      (value.status === "ok" ? coverage.complete !== true || coverage.total !== coverage.returned :
        coverage.complete !== false || coverage.returned !== 0 || coverage.total !== null)) {
    throw new TypeError("Invalid snapshot coverage");
  }
  const seen = new Set();
  const participants = value.participants.map(participant => {
    if (!isObject(participant) || typeof participant.participant_id !== "string" || !UUID.test(participant.participant_id) ||
        seen.has(participant.participant_id.toLowerCase()) || typeof participant.public_name !== "string" ||
        !reference(participant.ref, "participant", participant.participant_id)) {
      throw new TypeError("Invalid participant");
    }
    seen.add(participant.participant_id.toLowerCase());
    const position = participant.position;
    if (position !== null && (!isObject(position) || !numeric(position.lat) || Math.abs(position.lat) > 90 ||
        !numeric(position.lng) || Math.abs(position.lng) > 180 || !numeric(position.accuracy_m) ||
        position.accuracy_m < 0 || !time(position.occurred_at) || !time(position.received_at) ||
        Date.parse(position.occurred_at) > generated + 300000 || Date.parse(position.received_at) > generated + 30000 ||
        typeof position.provider !== "string" || position.provider.length > 32 || typeof position.is_mock !== "boolean" ||
        !reference(position.observation_ref, "location_observation"))) {
      throw new TypeError("Invalid location observation");
    }
    return {
      participant_id: participant.participant_id.toLowerCase(), ref: copyRef(participant.ref),
      public_name: participant.public_name,
      position: position === null ? null : {
        observation_ref: copyRef(position.observation_ref),
        lat: position.lat, lng: position.lng, accuracy_m: position.accuracy_m,
        occurred_at: position.occurred_at, received_at: position.received_at,
        provider: position.provider, is_mock: position.is_mock
      }
    };
  });
  return {
    schema_version: 2, status: value.status, generated_at: value.generated_at, limit: MAX_PARTICIPANTS,
    scope: { key: value.scope.key, organization: copyRef(value.scope.organization) },
    query: { area: "organization", time: "latest" },
    coordinates: { crs: "EPSG:4326", units: "degrees", order: "named_lat_lng" },
    source: { kind: "dispatch_location_projection", revision: value.source.revision },
    cursor: { stream_id: value.cursor.stream_id.toLowerCase(), sequence: value.cursor.sequence },
    coverage: { population: "active_participants", complete: coverage.complete, returned: coverage.returned,
      total: coverage.total, limit: MAX_PARTICIPANTS, next_cursor: null },
    work_access: value.work_access, participants
  };
}

export function parseSnapshot(text, now = Date.now(), options) {
  if (typeof text !== "string" || text.length > MAX_SNAPSHOT_BYTES ||
      new TextEncoder().encode(text).byteLength > MAX_SNAPSHOT_BYTES) {
    throw new TypeError("Location snapshot is too large");
  }
  return validateSnapshot(JSON.parse(text), now, options);
}

export function observationPresentation(position, now = Date.now()) {
  const signedAge = Math.floor((now - Date.parse(position.occurred_at)) / 1000);
  const ageSeconds = Math.max(0, signedAge);
  const treatment = signedAge < 0 ? { color: freshness(Infinity).color, label: "CLOCK AHEAD" } : freshness(ageSeconds);
  const age = ageSeconds < 60 ? `${ageSeconds}s` : ageSeconds < 3600 ? `${Math.floor(ageSeconds / 60)}m` : `${Math.floor(ageSeconds / 3600)}h`;
  return {
    ...treatment,
    ageSeconds,
    text: `${signedAge < 0 ? `${-signedAge}s ahead (device clock)` : `${age} ago`} · ±${Math.ceil(position.accuracy_m)} m${treatment.label ? ` · ${treatment.label}` : ""}${position.is_mock ? " · MOCK" : ""}`
  };
}

/** Bound presentation cost without rejecting a valid long roster name. */
export function participantLabel(name) {
  const characters = Array.from(name.trim() || "Unnamed participant");
  return characters.length > 120 ? `${characters.slice(0, 117).join("")}…` : characters.join("");
}
