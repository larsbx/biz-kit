import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { MAX_SNAPSHOT_BYTES, observationPresentation, parseSnapshot, participantLabel, validateSnapshot } from "../../../apps/dispatch/priv/static/js/maps/dispatch-map-model.js";
import { snapshot } from "./fixtures.mjs";

const NOW = Date.UTC(2026, 10, 11, 12);

test("valid snapshots retain only permitted fields and null positions", () => {
  const value = snapshot(NOW);
  value.secret = "discard";
  value.participants[0].position.extra = "discard";
  value.participants[1].position = null;
  const result = validateSnapshot(value, NOW);
  assert.equal(result.secret, undefined);
  assert.equal(result.participants[0].position.extra, undefined);
  assert.equal(result.participants[1].position, null);
});

test("schema, duplicate IDs, capacity and observation errors reject the entire snapshot", () => {
  const mutations = [
    value => { value.schema_version = 2; },
    value => { value.limit = 201; },
    value => { value.status = "guessed"; },
    value => { value.participants[1].participant_id = value.participants[0].participant_id.toUpperCase(); },
    value => { value.participants[0].participant_id = "../somewhere"; },
    value => { value.participants[0].position.lat = "47.61"; },
    value => { value.participants[0].position.lat = 91; },
    value => { value.participants[0].position.lng = -181; },
    value => { value.participants[0].position.accuracy_m = -1; },
    value => { value.participants[0].position.accuracy_m = Infinity; },
    value => { value.participants[0].position.is_mock = "false"; },
    value => { value.participants[0].position.provider = {}; },
    value => { value.participants[0].position.occurred_at = "yesterday"; },
    value => { value.participants[0].position.received_at = new Date(NOW + 31000).toISOString(); },
    value => { value.participants = Array(201).fill(value.participants[0]); },
    value => { value.status = "capacity_exceeded"; }
  ];
  for (const mutate of mutations) {
    const value = snapshot(NOW); mutate(value);
    assert.throws(() => validateSnapshot(value, NOW), TypeError);
  }
});

test("a capacity response has no private partial roster", () => {
  const value = { ...snapshot(NOW), status: "capacity_exceeded", participants: [] };
  assert.equal(validateSnapshot(value, NOW).participants.length, 0);
});

test("expired or future server snapshots cannot refresh the display", () => {
  assert.throws(() => validateSnapshot(snapshot(NOW - 45001), NOW));
  assert.throws(() => validateSnapshot(snapshot(NOW + 30001), NOW));
});

test("five-minute accepted device skew remains visible with honest clock labeling", () => {
  const value = snapshot(NOW);
  value.participants[0].position.occurred_at = new Date(NOW + 300000).toISOString();
  const accepted = validateSnapshot(value, NOW);
  const display = observationPresentation(accepted.participants[0].position, NOW);
  assert.equal(display.label, "CLOCK AHEAD");
  assert.match(display.text, /300s ahead \(device clock\)/);
  value.participants[0].position.occurred_at = new Date(NOW + 300001).toISOString();
  assert.throws(() => validateSnapshot(value, NOW));
});

test("freshness uses existing two-minute gray and five-minute stale thresholds", () => {
  const position = snapshot(NOW).participants[0].position;
  const present = age => observationPresentation({ ...position, occurred_at: new Date(NOW - age * 1000).toISOString() }, NOW);
  assert.notEqual(present(119).color, present(120).color);
  assert.equal(present(299).label, null);
  assert.equal(present(300).label, "STALE");
  assert.match(observationPresentation(snapshot(NOW).participants[1].position, NOW).text, /MOCK/);
});

test("long and markup-like public names remain text and are bounded only for display", () => {
  const value = snapshot(NOW);
  value.participants[0].public_name = "<img src=x onerror=alert(1)>" + "x".repeat(5000);
  const result = validateSnapshot(value, NOW);
  assert.equal(result.participants[0].public_name, value.participants[0].public_name);
  assert.ok(Array.from(participantLabel(result.participants[0].public_name)).length <= 120);
  assert.equal(participantLabel("   "), "Unnamed participant");
});

test("malformed and oversized JSON are rejected before display", () => {
  assert.throws(() => parseSnapshot("not json", NOW));
  assert.throws(() => parseSnapshot(" ".repeat(MAX_SNAPSHOT_BYTES + 1), NOW));
  const value = snapshot(NOW);
  value.participants[0].public_name = "界".repeat(100000);
  const text = JSON.stringify(value);
  assert.ok(text.length < MAX_SNAPSHOT_BYTES);
  assert.throws(() => parseSnapshot(text, NOW));
});

test("runtime dependency and generated asset manifest remain pinned and local", async () => {
  const packageJson = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
  assert.deepEqual(packageJson.dependencies, { cesium: "1.138.0" });
  const manifest = JSON.parse(await readFile(new URL("../../../apps/dispatch/priv/static/vendor/cesium/manifest.json", import.meta.url), "utf8"));
  assert.equal(manifest.version, "1.138.0");
  assert.ok(manifest.files.some(file => file.path === "Assets/Textures/NaturalEarthII/0/0/0.jpg"));
  assert.ok(!manifest.files.some(file => file.path === "Cesium.js"));
  assert.ok(manifest.files.every(file => /^[a-f0-9]{64}$/.test(file.sha256)));
});
