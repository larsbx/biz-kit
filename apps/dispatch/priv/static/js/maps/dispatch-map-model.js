import { freshness } from "./map-freshness.js";

export const MAX_PARTICIPANTS = 200;
export const MAX_SNAPSHOT_BYTES = 262144;
export const SNAPSHOT_TIMEOUT_MS = 45000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/;

const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
const numeric = value => typeof value === "number" && Number.isFinite(value);
const time = value => typeof value === "string" && ISO_TIME.test(value) && Number.isFinite(Date.parse(value));

/** Fail the complete snapshot closed; partial validation cannot retain old data. */
export function validateSnapshot(value, now = Date.now()) {
  if (!object(value) || value.schema_version !== 1 || value.limit !== MAX_PARTICIPANTS ||
      !["ok", "capacity_exceeded"].includes(value.status) || !time(value.generated_at) ||
      !Array.isArray(value.participants) || value.participants.length > MAX_PARTICIPANTS) {
    throw new TypeError("Invalid location snapshot");
  }
  const generated = Date.parse(value.generated_at);
  if (generated > now + 30000 || now - generated > SNAPSHOT_TIMEOUT_MS) {
    throw new TypeError("Location snapshot is not current");
  }
  if (value.status === "capacity_exceeded" && value.participants.length !== 0) {
    throw new TypeError("Capacity response must contain no locations");
  }
  const seen = new Set();
  const participants = value.participants.map(participant => {
    if (!object(participant) || !UUID.test(participant.participant_id) ||
        seen.has(participant.participant_id.toLowerCase()) || typeof participant.public_name !== "string") {
      throw new TypeError("Invalid participant");
    }
    seen.add(participant.participant_id.toLowerCase());
    const position = participant.position;
    if (position !== null && (!object(position) || !numeric(position.lat) || Math.abs(position.lat) > 90 ||
        !numeric(position.lng) || Math.abs(position.lng) > 180 || !numeric(position.accuracy_m) ||
        position.accuracy_m < 0 || !time(position.occurred_at) || !time(position.received_at) ||
        Date.parse(position.occurred_at) > generated + 300000 || Date.parse(position.received_at) > generated + 30000 ||
        typeof position.provider !== "string" || position.provider.length > 32 || typeof position.is_mock !== "boolean")) {
      throw new TypeError("Invalid location observation");
    }
    // Retain only the protocol's allowlisted fields; never carry arbitrary
    // server fields into a renderer, link, browser store or console.
    return {
      participant_id: participant.participant_id,
      public_name: participant.public_name,
      position: position === null ? null : {
        lat: position.lat, lng: position.lng, accuracy_m: position.accuracy_m,
        occurred_at: position.occurred_at, received_at: position.received_at,
        provider: position.provider, is_mock: position.is_mock
      }
    };
  });
  return { schema_version: 1, status: value.status, generated_at: value.generated_at, limit: MAX_PARTICIPANTS, participants };
}

export function parseSnapshot(text, now = Date.now()) {
  if (typeof text !== "string" || text.length > MAX_SNAPSHOT_BYTES ||
      new TextEncoder().encode(text).byteLength > MAX_SNAPSHOT_BYTES) {
    throw new TypeError("Location snapshot is too large");
  }
  return validateSnapshot(JSON.parse(text), now);
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
