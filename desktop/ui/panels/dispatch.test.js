import { test } from "node:test";
import assert from "node:assert/strict";
import panel, {
  idempotencyKeyFor, requestOptions, makeApi, problem, pickRole, filterLoads, upsertLoad,
  createLoadRequest, saveLoadRequest, addStopRequest, planTripRequest, transitionRequest,
  tripActions, needsConfirm, transitionAsk, summary, canAddStop, canPlanTrip, routeText,
  activeTrip, loadClass, tripClass, blank, iso,
} from "./dispatch.js";

const load = (over = {}) => ({
  load_id: "L1", external_reference: "PO-1", commodity_text: "steel", status: "DRAFT",
  created_at: "2026-11-10T00:00:00Z", version: 4, stops: [], trips: [], ...over,
});
const trip = (over = {}) => ({
  assignment_id: "T1", operator_participant_id: "D1", vehicle_id: null, trailer_id: null,
  status: "PLANNED", starts_at: "2026-11-10T00:00:00Z", ends_at: null, version: 7, ...over,
});

test("panel metadata follows the contract and is hostless", () => {
  assert.equal(panel.id, "dispatch");
  assert.equal(panel.label, "Dispatch");
  assert.equal(panel.group, "Business");
  assert.equal(panel.icon, "dispatch");
  assert.equal(panel.requiresHosts, false);
  assert.equal(typeof panel.mount, "function");
});

test("reads carry no idempotency key; every write mints a fresh one", () => {
  let n = 0;
  const uuid = () => `k${++n}`;
  assert.equal(idempotencyKeyFor("GET", uuid), undefined);
  assert.equal(idempotencyKeyFor("POST", uuid), "k1");
  assert.equal(idempotencyKeyFor("PATCH", uuid), "k2");
  assert.equal(n, 2);
  const real = idempotencyKeyFor("POST");
  assert.match(real, /^[0-9a-f-]{36}$/);
  assert.notEqual(real, idempotencyKeyFor("POST"));
});

test("request options carry the role, or none when unset", () => {
  assert.deepEqual(requestOptions("GET", undefined, "R1", () => "x"),
    { body: undefined, roleAssignmentId: "R1", idempotencyKey: undefined });
  assert.deepEqual(requestOptions("POST", { a: 1 }, "", () => "x"),
    { body: { a: 1 }, roleAssignmentId: undefined, idempotencyKey: "x" });
});

test("makeApi: one key per call, role read at call time, refusals become messages", async () => {
  const calls = [];
  let role = "R1";
  let reply = { status: 200, body: { ok: true } };
  let unauth = 0;
  let n = 0;
  const api = makeApi({
    request: async (method, path, opts) => { calls.push({ method, path, opts }); return reply; },
    getRole: () => role,
    onUnauthorized: async () => { unauth++; },
    uuid: () => `k${++n}`,
  });
  assert.deepEqual(await api("POST", "/v1/operations/loads", { x: 1 }), { ok: true });
  role = "R2";
  await api("POST", "/v1/operations/loads", { x: 1 });
  assert.equal(calls[0].opts.idempotencyKey, "k1");
  assert.equal(calls[1].opts.idempotencyKey, "k2"); // a second click is a second request
  assert.equal(calls[0].opts.roleAssignmentId, "R1");
  assert.equal(calls[1].opts.roleAssignmentId, "R2");

  reply = { status: 401, body: null };
  await assert.rejects(api("GET", "/v1/operations/loads"), /Signed out. Sign in again./);
  assert.equal(unauth, 1);

  reply = { status: 409, body: { detail: "stale version", code: "conflict" } };
  await assert.rejects(api("PATCH", "/v1/x", {}), /^Error: stale version \(conflict\)$/);
  reply = { status: 500, body: "boom" };
  await assert.rejects(api("GET", "/v1/x"), /^Error: HTTP 500$/);
});

test("problem formatting", () => {
  assert.equal(problem({ detail: "d", code: "c" }, 400), "d (c)");
  assert.equal(problem({ detail: "d" }, 400), "d");
  assert.equal(problem(null, 502), "HTTP 502");
});

test("role choice: keep held role, else the only one, else none", () => {
  const roles = [{ id: "a", label: "A" }, { id: "b", label: "B" }];
  assert.equal(pickRole(roles, "b"), "b");
  assert.equal(pickRole(roles, "gone"), "");
  assert.equal(pickRole([{ id: "only" }], ""), "only");
  assert.equal(pickRole([], "x"), "");
});

test("write requests: paths, bodies, version fields", () => {
  assert.deepEqual(createLoadRequest({ external_reference: "  PO ", commodity_text: " " }), {
    method: "POST", path: "/v1/operations/loads", body: { external_reference: "PO", commodity_text: null },
  });
  assert.deepEqual(saveLoadRequest(load(), { external_reference: "X", commodity_text: "" }), {
    method: "PATCH", path: "/v1/operations/loads/L1",
    body: { external_reference: "X", commodity_text: null, expected_version: 4 },
  });
  const stop = addStopRequest(load(), {
    kind: "DELIVERY", address_text: " 1 Main ", window_start: "2026-11-10T08:00", window_end: "",
    contact_name: "", contact_phone_e164: "+15551234567",
  });
  assert.equal(stop.path, "/v1/operations/loads/L1/stops");
  assert.equal(stop.body.address_text, "1 Main");
  assert.equal(stop.body.window_start, new Date("2026-11-10T08:00").toISOString());
  assert.equal(stop.body.window_end, null);
  assert.equal(stop.body.contact_name, null);
  assert.equal(stop.body.contact_phone_e164, "+15551234567");
  assert.deepEqual(planTripRequest(load(), { operator_participant_id: "D1", vehicle_id: "V1", trailer_id: "", starts_at: "" }), {
    method: "POST", path: "/v1/operations/loads/L1/trips",
    body: { operator_participant_id: "D1", vehicle_id: "V1", trailer_id: null, starts_at: null },
  });
  assert.deepEqual(transitionRequest(trip(), "cancel"), {
    method: "POST", path: "/v1/operations/trips/T1/transitions", body: { action: "cancel", expected_version: 7 },
  });
});

test("trip actions by status; only activation skips confirmation", () => {
  assert.deepEqual(tripActions("PLANNED"), ["activate", "cancel"]);
  assert.deepEqual(tripActions("ACTIVE"), ["complete", "cancel"]);
  assert.deepEqual(tripActions("COMPLETED"), []);
  assert.deepEqual(tripActions("CANCELLED"), []);
  assert.equal(needsConfirm("activate"), false);
  assert.equal(needsConfirm("complete"), true);
  assert.equal(needsConfirm("cancel"), true);
  const ask = transitionAsk(trip(), "complete", "Ana");
  assert.equal(ask.title, "Complete Ana's trip?");
  assert.equal(ask.danger, true);
  assert.equal(ask.command, 'POST /v1/operations/trips/T1/transitions\n{"action": "complete", "expected_version": 7}');
  assert.equal(transitionAsk(trip(), "cancel").title, "Cancel this driver's trip?");
});

test("board filtering and upsert", () => {
  const loads = [
    load({ load_id: "a", status: "BOOKED", stops: [{ address_text: "Detroit" }] }),
    load({ load_id: "b", status: "DELIVERED", external_reference: "zz" }),
  ];
  assert.deepEqual(filterLoads(loads, "open", "").map((l) => l.load_id), ["a"]);
  assert.deepEqual(filterLoads(loads, "all", "").map((l) => l.load_id), ["a", "b"]);
  assert.deepEqual(filterLoads(loads, "all", " detroit ").map((l) => l.load_id), ["a"]);
  const up = upsertLoad(loads, load({ load_id: "b", version: 9 }));
  assert.equal(up[1].version, 9);
  assert.notEqual(up, loads);
  assert.equal(upsertLoad(loads, load({ load_id: "c" }))[0].load_id, "c");
});

test("summary, enablement and display helpers", () => {
  assert.equal(summary({ status: null }), "");
  assert.equal(summary({ status: { api: null } }), "not configured");
  assert.equal(summary({ status: { api: "x", signedIn: false } }), "signed out");
  assert.equal(summary({ status: { api: "x", signedIn: true }, role: "", loads: [] }), "no role");
  const loads = [load({ trips: [trip({ status: "ACTIVE" }), trip({ status: "PLANNED" })] }), load()];
  assert.equal(summary({ status: { api: "x", signedIn: true }, role: "R", loads }), "2 loads · 1 active trip");
  assert.equal(canAddStop(false, { address_text: "  " }), false);
  assert.equal(canAddStop(true, { address_text: "x" }), false);
  assert.equal(canAddStop(false, { address_text: "x" }), true);
  assert.equal(canPlanTrip(false, { operator_participant_id: "" }), false);
  assert.equal(canPlanTrip(false, { operator_participant_id: "D" }), true);
  assert.equal(routeText(load()), "no stops");
  assert.equal(routeText(load({ stops: [{ address_text: "A" }, { address_text: "B" }, { address_text: "C" }] })), "A → C");
  assert.equal(activeTrip(load({ trips: [trip(), trip({ assignment_id: "T2", status: "ACTIVE" })] })).assignment_id, "T2");
  assert.equal(loadClass("IN_TRANSIT"), "ok");
  assert.equal(loadClass("DRAFT"), "");
  assert.equal(loadClass("BOOKED"), "warn");
  assert.equal(tripClass("CANCELLED"), "bad");
  assert.equal(blank("  "), null);
  assert.equal(iso(""), null);
});
