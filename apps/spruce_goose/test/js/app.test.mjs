// The web view's pure modules, against the ledger's own committed vectors
// (apps/coop_substrate/test/vectors). Run: node --test apps/spruce_goose/test/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { decode, encode, hex } from "../../priv/static/app/cbor.js";
import {
  sign,
  keyId,
  isOwnEnrolment,
  isExpectedCommand,
  same,
  governanceReadBytes,
  isExpectedBatch,
} from "../../priv/static/app/device.js";
import {
  applyFrame,
  emptyView,
  pendingSuggestions,
  base64url,
  timingForm,
  formTiming,
  taskSummary,
  projectSearch,
  projectsHeld,
  chapterKinds,
  changedKinds,
  ownDevices,
  chapterProjects,
  chapterAdministrators,
  chapterOffboarding,
  workflows,
  runTaskIds,
  runOf,
  runs,
  runReadiness,
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

test("encodes every committed vector to its exact canonical bytes", () => {
  for (const v of vectors.vectors) {
    assert.equal(hex(encode(decode(fromHex(v.canonical_hex)))), v.canonical_hex, v.name);
  }
  // Keys sorted over their encodings: shorter first, then bytewise.
  assert.equal(hex(encode({ bb: 1, a: 2, c: 3 })), "a3616102616303626262" + "01");
  assert.throws(() => encode(1.5));
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
    role: "operator",
  };

  assert.equal(isOwnEnrolment(statement, own), true);
  // A reviewer request is its own, and only as a reviewer.
  const asReviewer = { ...statement, role: "reviewer" };
  assert.equal(isOwnEnrolment(asReviewer, { ...own, role: "reviewer" }), true);
  assert.equal(isOwnEnrolment(asReviewer, own), false);
  assert.equal(isOwnEnrolment(statement, { ...own, role: "reviewer" }), false);
  for (const tampered of [
    { ...statement, schema: "CoopFeedReadV1" },
    { ...statement, type: "TaskOperatorGrantedV1" },
    { ...statement, key_id: "k-ffffffff" },
    { ...statement, pubkey: { __bytes__: "ff".repeat(32) } },
    { ...statement, role: undefined },
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
  const noSop = nextStep("t1", view({ state: "proposed", dod: {}, readiness }), "me", "k-me");
  assert.match(noSop.waiting, /SOP \(aaaaaaaaaaaa…\)/);
  // A file this device can store: the SOP's own digest.
  assert.equal(noSop.upload, sop);

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
  const noInput = nextStep("t1", { ...view({}), ...done }, "me", "k-me");
  assert.match(noInput.waiting, /input “input”/);
  assert.equal(noInput.upload, input);
  // Waiting on people, not files: nothing to upload.
  assert.equal(nextStep("t1", view({ state: "proposed", dod: null }), "me", "k-me").upload, undefined);
  // Ready: whoever starts acknowledged the SOP on this device.
  assert.deepEqual(nextStep("t1", view({ state: "ready", dod: {}, readiness: mine }, stored), "me", "k-me"), {
    action: "start",
    label: "Start",
  });
  assert.equal(nextStep("t1", view({ state: "ready", dod: {}, readiness: otherDevice }, stored), "me", "k-me").action, "acknowledge_sop");
  assert.equal(nextStep("t1", view({ state: "completed", dod: {}, readiness: mine }), "me", "k-me"), null);

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

test("under way: evidence, then a review, then completion; what is left to review", async () => {
  const { nextStep, toReview } = await import("../../priv/static/app/view.js");
  const criteria = [{ id: "report", description: "Report" }];
  const task = (dod) => ({ tasks: { t1: { state: "in_progress", title: "Audit", dod: { criteria, ...dod } } } });
  const submission = { event_id: "e1", principal_id: "me" };

  assert.deepEqual(nextStep("t1", task({ submission: null, review: null }), "me", "k-me"), {
    evidence: criteria,
    label: "Submit evidence…",
  });
  assert.deepEqual(nextStep("t1", task({ submission, review: null }), "me", "k-me"), {
    waiting: "a review of the evidence",
  });

  const refused = { event_id: "e2", decision: "refuse", reason: "Missing page 2", submission_event_id: "e1" };
  assert.deepEqual(nextStep("t1", task({ submission, review: refused }), "me", "k-me"), {
    evidence: criteria,
    label: "Submit evidence again…",
    refused,
  });

  const accepted = { ...refused, decision: "accept" };
  assert.deepEqual(nextStep("t1", task({ submission, review: accepted }), "me", "k-me"), {
    action: "complete",
    label: "Complete",
    review_event_id: "e2",
  });
  // An accepting review of another submission completes nothing.
  assert.equal(nextStep("t1", task({ submission, review: { ...accepted, submission_event_id: "e0" } }), "me", "k-me").action, undefined);

  // A reviewer sees others' unreviewed submissions, never their own.
  assert.deepEqual(toReview(task({ submission, review: null }), "reviewer"), [
    { id: "t1", title: "Audit", criteria, submission },
  ]);
  assert.deepEqual(toReview(task({ submission, review: null }), "me"), []);
  assert.deepEqual(toReview(task({ submission, review: accepted }), "reviewer"), []);
  assert.deepEqual(toReview(task({ submission: null, review: null }), "reviewer"), []);
});

test("calling a task off: cancel before the work starts, send back once under way", async () => {
  const { otherSteps, cancelledBecause } = await import("../../priv/static/app/view.js");
  const view = (state, extra = {}) => ({ tasks: { t1: { state, ...extra } } });

  for (const state of ["inbox", "proposed", "queued", "ready"])
    assert.deepEqual(otherSteps("t1", view(state)).map((s) => s.action), ["cancel"]);
  assert.deepEqual(otherSteps("t1", view("in_progress")).map((s) => s.action), ["reopen"]);
  for (const state of ["completed", "cancelled"]) assert.deepEqual(otherSteps("t1", view(state)), []);
  assert.deepEqual(otherSteps("nope", view("inbox")), []);

  assert.equal(
    cancelledBecause({ state: "cancelled", cancellation: { principal_id: "prn_a", reason: "Duplicate" } }),
    "Cancelled by prn_a: “Duplicate”",
  );
  assert.equal(
    cancelledBecause({ state: "cancelled", cancellation: { principal_id: null, reason: "Client withdrew" } }),
    "Cancelled by governance: “Client withdrew”",
  );
  assert.equal(cancelledBecause({ state: "queued" }), null);
});

test("administration: the governance read is the server's bytes; approvals and revocations are exact", async () => {
  const { grantFor, revocable, revocationType } = await import("../../priv/static/app/view.js");

  // CoopSubstrate.Governance.Read.signing_bytes/1 for the same request.
  const read = {
    method: "POST",
    path: "/api/v1/principals/prn_a/offboarding",
    timestamp_ms: 1792396800000,
    nonce: "AAAAAAAAAAAAAAAAAAAAAAAA",
    key_id: "k-01020304",
  };
  assert.equal(
    hex(governanceReadBytes(read)),
    "a6647061746878242f6170692f76312f7072696e636970616c732f70726e5f612f6f6666626f617264696e67656e6f6e63657818414141414141414141414141414141414141414141414141666b65795f69646a6b2d3031303230333034666d6574686f6464504f535466736368656d6174436f6f70476f7665726e616e63655265616456316c74696d657374616d705f6d731b000001a1532cb000",
  );

  const details = {
    principal_id: "prn_x",
    chapter_id: "c",
    tenant_id: "t",
    project_id: "p",
    key_id: "k-01020304",
    public_key: "AQIDBA",
    label: "Laptop",
    role: "reviewer",
  };
  assert.deepEqual(grantFor(details), {
    type: "TaskReviewerGrantedV1",
    payload: { tenant_id: "t", project_id: "p", principal_id: "prn_x", key_id: "k-01020304", pubkey: { __bytes__: "01020304" }, device_label: "Laptop" },
  });
  assert.equal(grantFor({ ...details, role: "operator" }).type, "TaskOperatorGrantedV1");
  assert.deepEqual(grantFor({ ...details, role: "governance" }), {
    type: "RoleKeyDeclared",
    payload: { role: "governance", key_id: "k-01020304", pubkey: { __bytes__: "01020304" }, member_id: "prn_x" },
  });

  // Exact: nothing may ride along, and only for this chapter.
  const { type, payload } = grantFor(details);
  const core = { chapter_id: "c", type, payload, signers: [{ key_id: "k-admin", role: "governance" }] };
  const expected = { keyId: "k-admin", type, payload, chapter: "c", exact: true };
  assert.equal(isExpectedCommand(core, expected), true);
  assert.equal(isExpectedCommand({ ...core, payload: { ...payload, extra: 1 } }, expected), false);
  assert.equal(isExpectedCommand({ ...core, chapter_id: "other" }, expected), false);
  // Without `exact`, an extra field would pass: governance always uses it.
  assert.equal(isExpectedCommand({ ...core, payload: { ...payload, extra: 1 } }, { ...expected, exact: false }), true);

  const held = [
    { kind: "operator", event_id: "g1" },
    { kind: "suggester", event_id: "g2" },
    { kind: "reviewer", event_id: "g3" },
    { kind: "delegation", event_id: "d1" },
  ];
  assert.deepEqual(revocable(held).map((h) => h.event_id), ["g1", "g3"]);
  assert.equal(revocationType("reviewer"), "TaskReviewerRevokedV1");
  assert.equal(revocationType("operator"), "TaskOperatorRevokedV1");
});

test("own devices: the command each role signs to revoke each kind", async () => {
  const { ownRevocation } = await import("../../priv/static/app/view.js");
  const laptop = { id: "g1", kind: "operator" };
  const tablet = { id: "g2", kind: "reviewer" };
  const browser = { id: "k-0a0b0c0d", kind: "administrator" };
  const as = (enrolled, reviewing, governing) => ({ enrolled, reviewing, governing });

  assert.deepEqual(ownRevocation(as(true, true, true), tablet), {
    type: "TaskDeviceRevokedV1",
    payload: { revoked_grant_event_id: "g2" },
  });
  // An administrator key only as an administrator, whatever else this key is.
  assert.equal(ownRevocation(as(true, true, false), browser), null);
  assert.deepEqual(ownRevocation(as(true, false, true), browser), {
    type: "RoleKeyRevoked",
    payload: { role: "governance", key_id: "k-0a0b0c0d" },
  });
  assert.deepEqual(ownRevocation(as(false, true, true), laptop), {
    type: "TaskReviewerDeviceRevokedV1",
    payload: { revoked_grant_event_id: "g1" },
  });
  assert.deepEqual(ownRevocation(as(false, false, true), tablet), {
    type: "TaskReviewerRevokedV1",
    payload: { authorization_event_id: "g2" },
  });
  assert.deepEqual(ownRevocation(as(false, false, true), laptop).type, "TaskOperatorRevokedV1");
  assert.deepEqual(ownRevocation(as(false, false, true), browser), {
    type: "RoleKeyRevoked",
    payload: { role: "governance", key_id: "k-0a0b0c0d" },
  });
  assert.equal(ownRevocation(as(false, false, false), laptop), null);
});

test("a chapter's projects: their tasks, a link to each, and what a person holds in each", () => {
  assert.equal(taskSummary({}), "no tasks");
  assert.equal(taskSummary({ inbox: 2, ready: 1, completed: 3, cancelled: 1 }), "3 open, 3 completed, 1 cancelled");
  assert.equal(taskSummary({ completed: 1 }), "1 completed");

  // The same page, for another project of the chapter, keeping the provider.
  const search = projectSearch("?chapter=c%201&tenant=t&project=p&provider=dev", "t-2", "p/2");
  assert.deepEqual(Object.fromEntries(new URLSearchParams(search)), {
    chapter: "c 1",
    tenant: "t-2",
    project: "p/2",
    provider: "dev",
  });

  // Only this chapter's projects; the one open first, then in order.
  const found = {
    principal_id: "bob",
    projects: [
      { chapter_id: "c", tenant_id: "t", project_id: "a", held: [] },
      { chapter_id: "other", tenant_id: "t", project_id: "x", held: [] },
      { chapter_id: "c", tenant_id: "t", project_id: "b", held: [] },
    ],
  };
  assert.deepEqual(
    projectsHeld(found, ["c", "t", "b"]).map((p) => [p.project_id, p.here]),
    [
      ["b", true],
      ["a", false],
    ],
  );
});

test("live: a frame of any kind builds the view; the person's devices and the chapter's lists come from it", () => {
  const project = [
    {
      seq: 3,
      changes: [
        { kind: "devices", id: "k-admin", value: { kind: "administrator", grant_id: null, key_id: "k-admin", label: null } },
        { kind: "devices", id: "g-2", value: { kind: "reviewer", grant_id: "g-2", key_id: "k-tab", label: "Tablet" } },
        { kind: "devices", id: "g-1", value: { kind: "operator", grant_id: "g-1", key_id: "k-lap", label: "Laptop" } },
      ],
    },
    { seq: 4, changes: [{ kind: "devices", id: "g-2", value: null }] },
  ].reduce(applyFrame, emptyView());

  // Operator devices first, then reviewer devices, then administrator keys.
  assert.deepEqual(
    ownDevices(project).map((d) => [d.id, d.kind]),
    [
      ["g-1", "operator"],
      ["k-admin", "administrator"],
    ],
  );
  assert.deepEqual(changedKinds({ changes: [{ kind: "tasks" }, { kind: "devices" }, { kind: "tasks" }] }), new Set(["tasks", "devices"]));

  const chapter = applyFrame(emptyView(chapterKinds), {
    seq: 5,
    changes: [
      { kind: "projects", id: "t/b", value: { tenant_id: "t", project_id: "b", tasks: {}, grants: 0, people: [] } },
      { kind: "projects", id: "t/a", value: { tenant_id: "t", project_id: "a", tasks: { inbox: 1 }, grants: 1, people: ["p"] } },
      { kind: "administrators", id: "k-2", value: { principal_id: "p" } },
      { kind: "administrators", id: "k-1", value: { principal_id: null } },
    ],
  });
  assert.deepEqual(Object.keys(chapter).sort(), ["administrators", "projects"]);
  assert.deepEqual(chapterProjects(chapter).map((p) => p.project_id), ["a", "b"]);
  assert.deepEqual(chapterAdministrators(chapter), [
    { key_id: "k-1", principal_id: null },
    { key_id: "k-2", principal_id: "p" },
  ]);
});

test("offboarding from a chapter: every project and key, signed only as the exact batch shown", () => {
  const found = {
    principal_id: "bob",
    projects: [
      { chapter_id: "c", tenant_id: "t", project_id: "a", held: [] },
      { chapter_id: "other", tenant_id: "t", project_id: "x", held: [] },
      { chapter_id: "c", tenant_id: "t", project_id: "b", held: [] },
    ],
    keys: [
      { chapter_id: "c", key_id: "k-bob" },
      { chapter_id: "other", key_id: "k-elsewhere" },
    ],
  };
  const commands = chapterOffboarding(found, "c");
  assert.deepEqual(commands, [
    { type: "TaskPrincipalOffboardedV1", payload: { tenant_id: "t", project_id: "a", principal_id: "bob" } },
    { type: "TaskPrincipalOffboardedV1", payload: { tenant_id: "t", project_id: "b", principal_id: "bob" } },
    { type: "RoleKeyRevoked", payload: { role: "governance", key_id: "k-bob" } },
  ]);

  const core = ({ type, payload }, key_id = "k-admin", chapter_id = "c") => ({
    type,
    payload,
    chapter_id,
    signers: [{ role: "governance", key_id }],
  });
  const cores = commands.map((c) => core(c));
  const ok = (cs) => isExpectedBatch(cs, { keyId: "k-admin", chapter: "c", commands });

  assert.ok(ok(cores));
  assert.ok(ok([...cores].reverse()), "order is the server's");
  assert.ok(!ok(cores.slice(1)), "one missing");
  assert.ok(!ok([...cores, cores[0]]), "one extra");
  assert.ok(!ok([cores[0], cores[0], cores[2]]), "one twice, one missing");
  assert.ok(!ok([cores[0], cores[1], core({ ...commands[2], payload: { ...commands[2].payload, key_id: "k-admin" } })]));
  assert.ok(!ok([cores[0], cores[1], core({ ...commands[2], payload: { ...commands[2].payload, reason: "x" } })]));
  assert.ok(!ok([core(commands[0], "k-other"), cores[1], cores[2]]), "another signer");
  assert.ok(!ok([core(commands[0], "k-admin", "other"), cores[1], cores[2]]), "another chapter");
});

test("workflows: sorted, a run's task IDs checked, a run task's origin named", () => {
  const release = {
    roadmap_key: "q4",
    roadmap_name: "Fourth quarter",
    workflow_id: "release",
    name: "Release",
    definitions: [
      { id: "build", title: "Build", depends_on: [] },
      { id: "ship", title: "Ship", depends_on: ["build"] },
    ],
  };
  const view = [
    {
      seq: 1,
      changes: [
        { kind: "workflows", id: "q4/release", value: release },
        { kind: "workflows", id: "q1/audit", value: { ...release, roadmap_name: "First quarter", name: "Audit" } },
        { kind: "tasks", id: "r1-build", value: { title: "Build", blueprint: { roadmap_key: "q4", workflow_id: "release", definition_id: "build" } } },
      ],
    },
  ].reduce(applyFrame, emptyView());

  assert.deepEqual(workflows(view).map((w) => w.name), ["Audit", "Release"]);
  assert.deepEqual(runTaskIds(release, "r2", view.tasks), { ids: { build: "r2-build", ship: "r2-ship" } });
  assert.match(runTaskIds(release, "r1", view.tasks).error, /r1-build already exists/);
  assert.match(runTaskIds(release, "Autumn 7A", view.tasks).error, /lowercase/);
  assert.match(runTaskIds(release, "", view.tasks).error, /lowercase/);
  assert.equal(runOf(view.tasks["r1-build"], view), "From workflow Release, step build");
  assert.equal(runOf({ title: "Plain" }, view), null);
});

test("the device signs a run only with exactly the task IDs it named", () => {
  const fields = {
    revision_event_id: "e-rev",
    roadmap_key: "q4",
    workflow_id: "release",
    task_ids: { build: "r2-build", ship: "r2-ship" },
  };
  const core = (payload) => ({
    type: "TaskWorkflowInstantiatedV1",
    signers: [{ key_id: "k1" }],
    payload: { ...payload, principal_id: "alice", authorization_event_id: "g1" },
  });
  const expected = { keyId: "k1", type: "TaskWorkflowInstantiatedV1", payload: fields };

  assert.ok(isExpectedCommand(core(fields), expected));
  assert.ok(!isExpectedCommand(core({ ...fields, task_ids: { build: "r2-build", ship: "other" } }), expected));
  assert.ok(!isExpectedCommand(core({ ...fields, revision_event_id: "e-old" }), expected));
});

test("runs group a run's tasks; readiness covers exactly the tasks waiting", () => {
  const bp = (step, preds, inputs) => ({
    run_event_id: "e-run",
    roadmap_key: "q4",
    workflow_id: "release",
    definition_id: step,
    predecessor_ids: preds,
    artifact_requirements: inputs,
  });
  const view = {
    ...emptyView(),
    tasks: {
      "r1-build": { state: "proposed", version: 2, blueprint: bp("build", [], ["source"]) },
      "r1-ship": { state: "inbox", version: 1, blueprint: bp("ship", ["r1-build"], []) },
      "r0-build": { state: "completed", version: 9, blueprint: { ...bp("build", [], []), run_event_id: "e-old" } },
      plain: { state: "proposed", version: 2 },
    },
  };

  const [old, run] = runs(view);
  assert.deepEqual([old.name, old.done, old.tasks.length], ["r0", 1, 1]);
  assert.deepEqual([run.name, run.tasks.map((t) => t.id), run.pending.map((t) => t.id)], ["r1", ["r1-build", "r1-ship"], ["r1-build"]]);

  const sop = "a".repeat(64);
  const source = "b".repeat(64);
  const where = { tenant: "t1", project: "p1", sop };
  assert.match(runReadiness(run, { ...where, inputs: {} }).error, /r1-build needs a SHA-256 digest for “source”/);
  assert.match(runReadiness(run, { ...where, sop: "nope", inputs: {} }).error, /SOP/);
  assert.deepEqual(runReadiness(run, { ...where, inputs: { "r1-build": { source } } }).commands, [
    {
      type: "TaskReadinessDefinedV1",
      payload: {
        tenant_id: "t1",
        project_id: "p1",
        task_id: "r1-build",
        expected_version: 2,
        artifact_requirements: { source: { __bytes__: source } },
        predecessor_ids: [],
        sop_digest: { __bytes__: sop },
      },
    },
  ]);
  assert.match(runReadiness(old, { ...where, inputs: {} }).error, /no task of this run/);
  assert.equal(run.sop, null);

  const readied = { ...view.tasks["r1-build"], state: "queued", readiness: { sop_digest: sop } };
  const [, later] = runs({ ...view, tasks: { ...view.tasks, "r1-build": readied } });
  assert.equal(later.sop, sop);
});

test("a run's readiness may name the SOP's version; a later batch keeps it", () => {
  const blueprint = { run_event_id: "e-run", definition_id: "build", predecessor_ids: [], artifact_requirements: [] };
  const view = { ...emptyView(), tasks: { "r1-build": { state: "proposed", version: 2, blueprint } } };
  const [run] = runs(view);
  const where = { tenant: "t1", project: "p1", sop: "a".repeat(64), inputs: {} };

  assert.equal(runReadiness(run, { ...where, sopVersion: "1.2.0" }).commands[0].payload.sop_version, "1.2.0");
  assert.ok(!("sop_version" in runReadiness(run, { ...where, sopVersion: "" }).commands[0].payload));
  for (const bad of ["1.2", "v1.2.0", "01.2.0"])
    assert.match(runReadiness(run, { ...where, sopVersion: bad }).error, /MAJOR\.MINOR\.PATCH/);

  const readied = { state: "queued", version: 3, blueprint, readiness: { sop_digest: "a".repeat(64), sop_version: "1.2.0" } };
  const [later] = runs({ ...view, tasks: { "r1-build": readied, "r1-ship": { state: "proposed", version: 2, blueprint: { ...blueprint, definition_id: "ship" } } } });
  assert.deepEqual([later.sop, later.sopVersion], ["a".repeat(64), "1.2.0"]);
});

test("todos: in order, each with what may be done to it; completion waits for them", async () => {
  const { todoRows, newTodoId, nextStep } = await import("../../priv/static/app/view.js");
  const todos = [
    { id: "read", title: "Read", depends_on: [], state: "completed", version: 2 },
    { id: "answer", title: "Answer", depends_on: ["read"], state: "open", version: 1 },
    { id: "check", title: "Check", depends_on: ["answer"], state: "open", version: 1 },
    { id: "old", title: "Old", depends_on: [], state: "dropped", version: 2, reason: "Moot" },
  ];

  assert.deepEqual(
    todoRows({ state: "in_progress", todos }).map((r) => [r.id, r.complete, r.drop]),
    [["read", false, false], ["answer", true, false], ["check", false, true], ["old", false, false]],
  );
  // Nothing may change once the task is finished.
  assert.ok(todoRows({ state: "completed", todos }).every((r) => !r.complete && !r.drop));

  assert.equal(newTodoId("Read the chapter", todos), "read-the-chapter");
  assert.equal(newTodoId("Read", todos), "read-2");
  assert.equal(newTodoId("  !!  ", todos), "todo");

  const accepted = { event_id: "e2", decision: "accept", submission_event_id: "e1" };
  const task = (todos) => ({
    tasks: { t1: { state: "in_progress", todos, dod: { criteria: [], submission: { event_id: "e1" }, review: accepted } } },
  });
  assert.deepEqual(nextStep("t1", task(todos), "me", "k-me"), { waiting: "2 open todos" });
  assert.equal(nextStep("t1", task(todos.filter((t) => t.state !== "open")), "me", "k-me").action, "complete");
});
