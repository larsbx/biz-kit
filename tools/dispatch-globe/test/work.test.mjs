import assert from "node:assert/strict";
import test from "node:test";
import { createSelectedWork, validateWork } from "../../../apps/dispatch/priv/static/js/maps/dispatch-map-work.js";
import { IDS, OBSERVATION_IDS, SCOPE_KEY, snapshot, workFixture } from "./fixtures.mjs";

const NOW = Date.UTC(2026, 10, 11, 12);
const expected = { scope: snapshot(NOW).scope, participantId: IDS[0], observationId: OBSERVATION_IDS[0] };
const flush = async () => { for (let i = 0; i < 15; i++) await Promise.resolve(); };
function harness() {
  const requests = [], responses = [], values = [], statuses = [], timers = new Map();
  let clock = NOW, id = 0;
  const work = createSelectedWork({ expectedScopeKey: SCOPE_KEY,
    onValue: value => values.push(value), onStatus: value => statuses.push(value), now: () => clock,
    schedule: callback => { timers.set(++id, callback); return id; }, cancel: timer => timers.delete(timer),
    fetchImpl: (url, options) => {
      requests.push({ url, options });
      return responses.shift() || Promise.resolve(response(workFixture(clock)));
    }
  });
  function response(value, status = 200) { return { ok: status === 200, status, redirected: false,
    headers: new Headers({ "content-type": "application/json" }), text: async () => JSON.stringify(value) }; }
  return { work, requests, responses, values, statuses, timers, response,
    timeout() { clock += 15000; for (const callback of [...timers.values()]) callback(); } };
}

test("selected work is a strict typed read projection of the exact observation", () => {
  const value = workFixture(NOW); value.private_note = "discard"; value.load.payment = 100;
  const result = validateWork(value, expected, NOW);
  assert.equal(result.private_note, undefined); assert.equal(result.load.payment, undefined);
  assert.equal(result.next_stop.status, "unknown");
  assert.equal(result.stops[1].position, null);
  assert.match(result.load.record_href, /^\/operations\/loads\/[0-9a-f-]+$/);
});

test("foreign scope, substituted observation, unsafe links and false completeness are refused", () => {
  const mutations = [
    value => { value.scope.key = "c".repeat(64); },
    value => { value.scope.organization.id = IDS[1]; },
    value => { value.participant.id = IDS[1]; },
    value => { value.observation_ref.id = OBSERVATION_IDS[1]; },
    value => { value.assignment.ref.kind = "participant"; },
    value => { value.load.record_href = "https://outside.invalid/"; },
    value => { value.load.record_href = `/operations/loads/${IDS[1]}`; },
    value => { value.stops[0].position.lat = 92; },
    value => { value.stops[0].sequence = 0; },
    value => { value.stops[0].position_status = "unresolved"; },
    value => { value.stops[1].ref.id = value.stops[0].ref.id; },
    value => { value.stop_coverage.total = 10; },
    value => { value.next_stop.status = "next"; },
    value => { value.generated_at = new Date(NOW - 45001).toISOString(); }
  ];
  for (const mutate of mutations) { const value = workFixture(NOW); mutate(value); assert.throws(() => validateWork(value, expected, NOW)); }
});

test("no position or separate work permission means no detail request", async () => {
  const h = harness();
  await h.work.select(null, IDS[0]);
  await h.work.select({ ...snapshot(NOW), work_access: false }, IDS[0]);
  const noPosition = snapshot(NOW); noPosition.participants[0].position = null;
  await h.work.select(noPosition, IDS[0]);
  assert.equal(h.requests.length, 0); assert.equal(h.values.at(-1), null);
  h.work.destroy();
});

test("the work GET binds observation in a header, never in the URL", async () => {
  const h = harness(); await h.work.select(snapshot(NOW), IDS[0]);
  const request = h.requests[0];
  assert.equal(request.url, `/ui/operations/locations/${IDS[0]}/work`);
  assert.equal(request.options.headers["x-dispatch-observation"], OBSERVATION_IDS[0]);
  assert.equal(request.options.cache, "no-store"); assert.equal(request.options.credentials, "same-origin");
  assert.equal(request.options.redirect, "manual");
  assert.equal(h.statuses.at(-1), "ready"); assert.equal(h.timers.size, 0);
  h.work.destroy();
});

test("a late detail response after snapshot replacement cannot resurrect revoked work", async () => {
  const h = harness(); let resolve;
  h.responses.push(new Promise(done => { resolve = done; }));
  void h.work.select(snapshot(NOW), IDS[0]); await flush();
  const first = h.requests[0];
  await h.work.select({ ...snapshot(NOW), work_access: false }, IDS[0]);
  assert.equal(first.options.signal.aborted, true);
  resolve(h.response(workFixture(NOW))); await flush();
  assert.equal(h.values.at(-1), null); assert.notEqual(h.statuses.at(-1), "ready");
  h.work.destroy();
});

test("selection changes bind each response to its own participant and observation", async () => {
  const h = harness(); let resolve;
  h.responses.push(new Promise(done => { resolve = done; }));
  void h.work.select(snapshot(NOW), IDS[0]); await flush();
  h.responses.push(Promise.resolve(h.response(workFixture(NOW, IDS[1], OBSERVATION_IDS[1]))));
  await h.work.select(snapshot(NOW), IDS[1]);
  resolve(h.response(workFixture(NOW))); await flush();
  assert.equal(h.values.at(-1).participant.id, IDS[1]);
  h.work.destroy();
});

test("a replacement observation for the same selected participant cancels the old subject before accepting new work", async () => {
  const h = harness(); let resolveOld;
  const newObservation = "0193be40-0000-7000-8000-000000000013";
  h.responses.push(new Promise(done => { resolveOld = done; }));
  void h.work.select(snapshot(NOW), IDS[0]); await flush();
  const replacement = snapshot(NOW);
  replacement.participants[0].position.observation_ref.id = newObservation;
  h.responses.push(Promise.resolve(h.response(workFixture(NOW, IDS[0], newObservation))));
  await h.work.select(replacement, IDS[0]);
  assert.equal(h.requests[0].options.signal.aborted, true);
  assert.equal(h.requests[1].options.headers["x-dispatch-observation"], newObservation);
  assert.equal(h.values.at(-1).observation_ref.id, newObservation);
  const accepted = h.values.at(-1);
  resolveOld(h.response(workFixture(NOW))); await flush();
  assert.equal(h.values.at(-1), accepted);
  assert.equal(h.values.at(-1).participant.id, IDS[0]);
  assert.equal(h.values.at(-1).observation_ref.id, newObservation);
  h.work.destroy();
});

test("mismatched, stale, denied and timed-out work clears all details", async () => {
  for (const status of [401, 403, 404, 409, 422, 500]) {
    const h = harness(); h.responses.push(Promise.resolve(h.response({}, status)));
    await h.work.select(snapshot(NOW), IDS[0]);
    assert.equal(h.values.at(-1), null); assert.equal(h.timers.size, 0); h.work.destroy();
  }
  const h = harness(); let resolve;
  h.responses.push(new Promise(done => { resolve = done; }));
  void h.work.select(snapshot(NOW), IDS[0]); await flush(); h.timeout();
  assert.equal(h.requests[0].options.signal.aborted, true);
  resolve(h.response(workFixture(NOW))); await flush();
  assert.equal(h.values.at(-1), null); assert.equal(h.statuses.at(-1), "unavailable"); h.work.destroy();
});

test("work response bodies are bounded to the selected 64 KiB profile, including UTF-8 bytes", async () => {
  for (const oversizedText of ["x".repeat(65536), "🚚".repeat(17000)]) {
    const h = harness(); const value = workFixture(NOW);
    value.load.commodity_text = oversizedText;
    h.responses.push(Promise.resolve(h.response(value)));
    await h.work.select(snapshot(NOW), IDS[0]);
    assert.equal(h.values.at(-1), null); assert.equal(h.statuses.at(-1), "unavailable");
    h.work.destroy();
  }
});
