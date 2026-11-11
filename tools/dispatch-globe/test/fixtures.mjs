import { readFileSync } from "node:fs";

export const IDS = ["0193be40-0000-7000-8000-000000000001", "0193be40-0000-7000-8000-000000000002"];
export const OBSERVATION_IDS = ["0193be40-0000-7000-8000-000000000011", "0193be40-0000-7000-8000-000000000012"];
export const SCOPE_KEY = "b".repeat(64);
export const ORGANIZATION_ID = "0193be40-0000-7000-8000-000000000020";
export const GET_STREAM = "0193be40-0000-7000-8000-000000000030";
export const SSE_STREAM = "0193be40-0000-7000-8000-000000000031";
export const LOAD_ID = "0193be40-0000-7000-8000-000000000040";
export const ASSIGNMENT_ID = "0193be40-0000-7000-8000-000000000041";
export const STOP_IDS = ["0193be40-0000-7000-8000-000000000050", "0193be40-0000-7000-8000-000000000051"];

export function snapshot(now = Date.now(), { sequence = 0, streamId = GET_STREAM } = {}) {
  return {
    schema_version: 2, status: "ok", generated_at: new Date(now).toISOString(), limit: 200,
    scope: { key: SCOPE_KEY, organization: { kind: "organization", id: ORGANIZATION_ID } },
    query: { area: "organization", time: "latest" },
    coordinates: { crs: "EPSG:4326", units: "degrees", order: "named_lat_lng" },
    source: { kind: "dispatch_location_projection", revision: "a".repeat(64) },
    cursor: { stream_id: streamId, sequence },
    coverage: { population: "active_participants", complete: true, returned: 2, total: 2, limit: 200, next_cursor: null },
    work_access: true,
    participants: [
      { participant_id: IDS[0], ref: { kind: "participant", id: IDS[0] }, public_name: "North van",
        position: { observation_ref: { kind: "location_observation", id: OBSERVATION_IDS[0] }, lat: 47.61, lng: -122.33, accuracy_m: 35,
          occurred_at: new Date(now - 15000).toISOString(), received_at: new Date(now - 10000).toISOString(), provider: "fixture", is_mock: false } },
      { participant_id: IDS[1], ref: { kind: "participant", id: IDS[1] }, public_name: "South van",
        position: { observation_ref: { kind: "location_observation", id: OBSERVATION_IDS[1] }, lat: 37.77, lng: -122.42, accuracy_m: 250,
          occurred_at: new Date(now - 310000).toISOString(), received_at: new Date(now - 300000).toISOString(), provider: "fixture", is_mock: true } }
    ]
  };
}
export function streamSnapshot(now = Date.now(), sequence = 0) { return snapshot(now, { sequence, streamId: SSE_STREAM }); }
export function withParticipants(value, participants) {
  return { ...value, participants, coverage: { ...value.coverage, returned: participants.length, total: participants.length } };
}
export function capacitySnapshot(now = Date.now()) {
  return { ...snapshot(now), status: "capacity_exceeded", participants: [],
    coverage: { population: "active_participants", complete: false, returned: 0, total: null, limit: 200, next_cursor: null } };
}
export function workFixture(now = Date.now(), participantId = IDS[0], observationId = OBSERVATION_IDS[0]) {
  return {
    schema_version: 1, status: "ok", generated_at: new Date(now).toISOString(), scope: snapshot(now).scope,
    participant: { kind: "participant", id: participantId }, observation_ref: { kind: "location_observation", id: observationId },
    assignment: { ref: { kind: "assignment", id: ASSIGNMENT_ID }, status: "IN_PROGRESS", version: 3,
      starts_at: new Date(now - 3600000).toISOString(), ends_at: null, vehicle_ref: null, trailer_ref: null },
    load: { ref: { kind: "load", id: LOAD_ID }, external_reference: participantId === IDS[0] ? "North delivery" : "South delivery", commodity_text: "Packaged goods",
      status: "ACTIVE", version: 2, record_href: `/operations/loads/${LOAD_ID}` },
    stops: [
      { ref: { kind: "stop", id: STOP_IDS[0] }, sequence: 1, kind: "PICKUP", address_text: "North receiving yard",
        window_start: null, window_end: null, position: { lat: 47.615, lng: -122.335 }, position_status: "recorded" },
      { ref: { kind: "stop", id: STOP_IDS[1] }, sequence: 2, kind: "DELIVERY", address_text: "Destination awaiting accepted coordinates",
        window_start: null, window_end: null, position: null, position_status: "unresolved" }
    ],
    stop_coverage: { complete: true, returned: 2, total: 2, limit: 200 },
    next_stop: { status: "unknown", reason: "stop_progress_not_recorded" }
  };
}

// Use the production HEEx document, replacing only its two server-owned values.
// Browser entry import remains controlled so the gate can observe native entities.
const htmlSource = readFileSync(new URL("../../../apps/dispatch/lib/dispatch_web/controllers/fleet_map_html.ex", import.meta.url), "utf8");
export const SHELL = htmlSource.match(/~H"""([\s\S]*?)"""/)[1]
  .replace('data-scope-key={@scope_key}', `data-scope-key="${SCOPE_KEY}"`)
  .replace('{@actor.role_assignment.role_definition.label}', 'Test dispatcher')
  .replace(/<script type="module" src="\/static\/js\/maps\/dispatch-map.js">\s*<\/script>/, '');
if (SHELL.includes("{@")) throw new Error("Browser fixture has unhandled server values");

export const CREDIT_STYLE_HASH = "sha256-W9isZ7K65dw04+sGbSAyiFtvwt94eXJiQXtiU8lmkRg=";
export const CSP = `default-src 'self'; script-src 'self'; style-src 'self' '${CREDIT_STYLE_HASH}'; style-src-attr 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; font-src 'self'; worker-src 'self' blob:; object-src 'none'; frame-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`;
