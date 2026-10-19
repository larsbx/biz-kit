// The web view's pure modules, against the ledger's own committed vectors
// (apps/coop_substrate/test/vectors). Run: node --test apps/spruce_goose/test/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { decode, hex } from "../../priv/static/app/cbor.js";
import { sign, keyId, isOwnEnrolment, isExpectedCommand, same } from "../../priv/static/app/device.js";
import {
  applyFrame,
  emptyView,
  pendingSuggestions,
  base64url,
  timingForm,
  formTiming,
} from "../../priv/static/app/view.js";

const vectors = JSON.parse(
  readFileSync(new URL("../../../coop_substrate/test/vectors/canonical_v1_vectors.json", import.meta.url))
);

const fromHex = (h) => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));

// JSON numbers lose precision past 2^53; compare BigInts as numbers the same way.
const comparable = (v) =>
  typeof v === "bigint"
    ? Number(v)
    : Array.isArray(v)
      ? v.map(comparable)
      : v && typeof v === "object"
        ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, comparable(x)]))
        : v;

test("decodes every committed vector to its logical term", () => {
  for (const v of vectors.vectors) {
    assert.deepEqual(comparable(decode(fromHex(v.canonical_hex))), v.term, v.name);
  }
});

test("keeps integers past 2^53 exact", () => {
  // -2^63 and 2^63 - 1
  assert.equal(decode(fromHex("3b7fffffffffffffff")), -(2n ** 63n));
  assert.equal(decode(fromHex("1b7fffffffffffffff")), 2n ** 63n - 1n);
  assert.equal(decode(fromHex("1b001fffffffffffff")), 2 ** 53 - 1);
});

test("refuses what the profile forbids", () => {
  for (const [what, h] of [
    ["float", "f93c00"],
    ["tag", "c11a514b67b0"],
    ["indefinite array", "9f01ff"],
    ["trailing bytes", "0101"],
    ["truncated", "62ab"],
    ["integer map key", "a10102"],
    ["invalid UTF-8", "61ff"],
  ]) {
    assert.throws(() => decode(fromHex(h)), /not CoopEventCanonicalV1/, what);
  }
});

test("the browser's Ed25519 signature is the ledger's, byte for byte", async () => {
  // PKCS#8 wrapping of a raw Ed25519 seed (RFC 8410).
  const pkcs8 = fromHex("302e020100300506032b657004220420" + vectors.ed25519_seed_hex);
  const privateKey = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, false, ["sign"]);

  for (const v of vectors.vectors) {
    assert.equal(hex(await sign({ privateKey }, fromHex(v.canonical_hex))), v.sig_hex, v.name);
  }
});

test("key IDs follow the ledger's convention", () => {
  assert.equal(keyId(fromHex(vectors.ed25519_pubkey_hex)), "k-" + vectors.ed25519_pubkey_hex.slice(0, 8));
});

test("frames build the view; suggestions filter to pending", () => {
  const view = [
    { seq: 3, changes: [{ kind: "tasks", id: "t1", value: { title: "A" } }] },
    {
      seq: 5,
      changes: [
        { kind: "suggestions", id: "s1", value: { status: "pending", task_id: "t1" } },
        { kind: "suggestions", id: "s2", value: { status: "accepted", task_id: "t1" } },
        { kind: "tasks", id: "t1", value: { title: "B" } },
      ],
    },
  ].reduce(applyFrame, emptyView());

  assert.deepEqual(view.tasks, { t1: { title: "B" } });
  assert.deepEqual(pendingSuggestions(view), [{ id: "s1", status: "pending", task_id: "t1" }]);
});

test("base64url round-trips without padding", () => {
  const bytes = Uint8Array.from({ length: 65 }, (_, i) => (i * 37) % 256);
  const text = base64url.encode(bytes);
  assert.doesNotMatch(text, /[+/=]/);
  assert.deepEqual(base64url.decode(text), bytes);
});

test("the device signs only its own enrolment statement", () => {
  const own = { keyId: "k-01020304", publicKeyHex: "01020304" + "00".repeat(28) };
  const statement = {
    schema: "CoopDeviceEnrolmentV1",
    principal_id: "prn_x",
    key_id: own.keyId,
    pubkey: { __bytes__: own.publicKeyHex },
    label: "Laptop",
  };

  assert.equal(isOwnEnrolment(statement, own), true);
  for (const tampered of [
    { ...statement, schema: "CoopFeedReadV1" },
    { ...statement, type: "TaskOperatorGrantedV1" },
    { ...statement, key_id: "k-ffffffff" },
    { ...statement, pubkey: { __bytes__: "ff".repeat(32) } },
    null,
  ]) {
    assert.equal(isOwnEnrolment(tampered, own), false);
  }
});

test("the device signs only the command it was asked for", () => {
  const core = {
    type: "TaskDeviceRevokedV1",
    signers: [{ role: "operator", key_id: "k-01020304", pubkey: { __bytes__: "01" } }],
    payload: { revoked_grant_event_id: "g1", principal_id: "prn_x" },
  };
  const expected = { keyId: "k-01020304", type: "TaskDeviceRevokedV1", payload: { revoked_grant_event_id: "g1" } };

  assert.equal(isExpectedCommand(core, expected), true);
  for (const tampered of [
    { ...core, type: "TaskOperatorRevokedV1" },
    { ...core, payload: { ...core.payload, revoked_grant_event_id: "g2" } },
    { ...core, signers: [{ ...core.signers[0], key_id: "k-ffffffff" }] },
    { ...core, signers: [...core.signers, ...core.signers] },
    {},
    null,
  ]) {
    assert.equal(isExpectedCommand(tampered, expected), false);
  }
});

test("an amended command is signed only with exactly the timing entered", () => {
  const timing = { schedule: { kind: "timed", start_ms: 1792396800000, end_ms: 1792400400000, tz: "UTC" }, due_ms: null };
  // As decoded from CBOR: integers may come back as BigInts.
  const decoded = { schedule: { ...timing.schedule, start_ms: 1792396800000n, end_ms: 1792400400000n }, due_ms: null };
  const core = {
    type: "TaskTimingRevisedV1",
    signers: [{ role: "operator", key_id: "k-01020304" }],
    payload: { suggestion_event_id: "s1", timing: decoded },
  };
  const expected = { keyId: "k-01020304", type: "TaskTimingRevisedV1", payload: { suggestion_event_id: "s1", timing } };

  assert.equal(isExpectedCommand(core, expected), true);
  const later = { ...decoded, schedule: { ...decoded.schedule, end_ms: 1792404000000n } };
  assert.equal(isExpectedCommand({ ...core, payload: { ...core.payload, timing: later } }, expected), false);
  assert.equal(isExpectedCommand({ ...core, payload: { ...core.payload, timing: { ...decoded, extra: 1 } } }, expected), false);
  assert.equal(same({ a: [1, 2n] }, { a: [1n, 2] }), true);
  assert.equal(same({ a: 1 }, { a: 1, b: undefined }), false);
});

const pad2 = (n) => String(n).padStart(2, "0");

test("the edit form round-trips a timing, and an untouched form keeps it exactly", () => {
  const timed = { schedule: { kind: "timed", start_ms: 1792396800000, end_ms: 1792400400000, tz: "Europe/Copenhagen" }, due_ms: 1792404000000 };
  const allDay = { schedule: { kind: "all_day", start_date: "2026-10-19", end_date: "2026-10-21" }, due_ms: null };
  const none = { schedule: null, due_ms: null };

  for (const t of [timed, allDay, none]) {
    assert.deepEqual(formTiming(timingForm(t), t, "UTC"), { timing: t });
    // A fresh form (no original) builds the same timing from the fields alone.
    assert.deepEqual(formTiming(timingForm(t), null, "Europe/Copenhagen"), { timing: t });
  }

  // All-day is shown with its last day; the ledger's end date is the day after.
  assert.equal(timingForm(allDay).last, "2026-10-20");
  // A second-precise original survives an untouched form.
  const seconds = { schedule: { ...timed.schedule, start_ms: timed.schedule.start_ms + 7000 }, due_ms: null };
  assert.deepEqual(formTiming(timingForm(seconds), seconds, "UTC"), { timing: seconds });

  // Editing one part keeps the other exactly, seconds included.
  const precise = { schedule: { ...timed.schedule, start_ms: timed.schedule.start_ms + 7000 }, due_ms: timed.due_ms + 4000 };
  const newDue = formTiming({ ...timingForm(precise), due: timingForm(none).due }, precise, "UTC").timing;
  assert.deepEqual(newDue, { schedule: precise.schedule, due_ms: null });
  const later = timingForm(timed).end.replace(/T(\d\d)/, (_, h) => `T${pad2(Number(h) + 1)}`);
  const newEnd = formTiming({ ...timingForm(precise), end: later }, precise, "UTC").timing;
  assert.equal(newEnd.due_ms, precise.due_ms);
  assert.equal(newEnd.schedule.end_ms, timed.schedule.end_ms + 3_600_000);

  const changed = { ...timingForm(timed), end: timingForm(timed).start };
  assert.match(formTiming(changed, timed, "UTC").error, /after the start/);
  assert.match(formTiming({ ...timingForm(allDay), last: "2026-10-18" }, allDay, "UTC").error, /before the first/);
  assert.deepEqual(formTiming({ ...timingForm(timed), kind: "none" }, timed, "UTC"), { timing: { schedule: null, due_ms: timed.due_ms } });
});

test("a task's next step, or what it is waiting for", async () => {
  const { nextStep, decidedSuggestions } = await import("../../priv/static/app/view.js");
  const sop = "aa".repeat(32);
  const input = "bb".repeat(32);
  const readiness = { sop_digest: sop, artifact_requirements: { input }, predecessor_ids: ["t0"], acknowledgment: null };
  const view = (task, extra = {}) => ({
    tasks: { t1: task, t0: { state: "ready" } },
    suggestions: {},
    delegations: {},
    receipts: {},
    ...extra,
  });

  assert.deepEqual(nextStep("t1", view({ state: "inbox" }), "me", "k-me"), { action: "propose", label: "Propose" });
  assert.deepEqual(nextStep("t1", view({ state: "proposed", dod: null }), "me", "k-me"), { waiting: "a Definition of Done" });
  assert.deepEqual(nextStep("t1", view({ state: "proposed", dod: {} }), "me", "k-me"), { waiting: "a readiness definition" });
  assert.match(nextStep("t1", view({ state: "proposed", dod: {}, readiness }), "me", "k-me").waiting, /SOP \(aaaaaaaaaaaa…\)/);

  const stored = { receipts: { r2: { digest: sop }, r1: { digest: input } } };
  assert.deepEqual(nextStep("t1", view({ state: "proposed", dod: {}, readiness }, stored), "me", "k-me"), {
    action: "acknowledge_sop",
    label: "Acknowledge the SOP",
    custody_receipt_id: "r2",
  });

  // Someone else's acknowledgement does not count for me.
  const theirs = { ...readiness, acknowledgment: { principal_id: "them" } };
  assert.equal(nextStep("t1", view({ state: "proposed", dod: {}, readiness: theirs }, stored), "me", "k-me").action, "acknowledge_sop");

  // Nor does mine from another device: the ledger checks the key.
  const otherDevice = { ...readiness, acknowledgment: { principal_id: "me", key_id: "k-other" } };
  assert.equal(nextStep("t1", view({ state: "proposed", dod: {}, readiness: otherDevice }, stored), "me", "k-me").action, "acknowledge_sop");

  const mine = { ...readiness, acknowledgment: { principal_id: "me", key_id: "k-me" } };
  assert.equal(nextStep("t1", view({ state: "proposed", dod: {}, readiness: mine }, stored), "me", "k-me").action, "queue");
  assert.deepEqual(nextStep("t1", view({ state: "queued", dod: {}, readiness: mine }, stored), "me", "k-me").waiting, "t0 to complete");

  const done = { tasks: { t1: { state: "queued", dod: {}, readiness: mine }, t0: { state: "completed" } } };
  assert.deepEqual(nextStep("t1", { ...view({}), ...stored, ...done }, "me", "k-me"), {
    action: "ready",
    label: "Mark ready",
    custody_receipts: { input: "r1" },
  });
  assert.match(nextStep("t1", { ...view({}), ...done }, "me", "k-me").waiting, /input “input”/);
  assert.equal(nextStep("t1", view({ state: "ready" }), "me", "k-me"), null);

  // Latest decided first: s1 was suggested first but decided last.
  const history = decidedSuggestions({
    suggestions: {
      s1: { status: "declined", resolved_by_event_id: "e9" },
      s2: { status: "withdrawn", reason: "changed plan", resolved_by_event_id: "e5" },
      s3: { status: "accepted", resolved_by_event_id: "e7" },
      s4: { status: "pending" },
    },
  });
  assert.deepEqual(history.map((s) => [s.id, s.status]), [["s1", "declined"], ["s3", "accepted"], ["s2", "withdrawn"]]);
});
