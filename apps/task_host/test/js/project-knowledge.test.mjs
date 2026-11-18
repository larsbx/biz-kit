import { test } from "node:test";
import assert from "node:assert/strict";
import { isExpectedCommand } from "../../priv/static/app/device.js";
import {
  knowledgeScope, projectKnowledgePath, projectKnowledgeLink, knowledgeContext,
  knowledgeSuggestionsURL, validateKnowledgeEnvelope, validateKnowledgeCandidate,
  knowledgeSnapshot, knowledgeReviewAllowed, knowledgeReviewCommand, knowledgeReviewRequest,
  KnowledgeRequests, renderKnowledgeDraft, ProjectKnowledgeQueue, retainedApproval, KnowledgeSuggestions,
} from "../../priv/static/app/project-knowledge.js";

const scope = { chapter_id: "chapter-one", tenant_id: "tenant-one", project_id: "project-one" };
const candidate = (fields = {}) => ({
  id: "task-" + "a".repeat(64), generator_version: 1, kind: "completed_task",
  title: "Accepted onboarding outcome", summary: "A source-backed record of completed work.",
  body: "The installer retained the evidence and the owner accepted the handoff.",
  source: { scope, task_id: "handoff", completion_event_id: "completion-01", review_event_id: "review-01", evidence_digest: "b".repeat(64) },
  source_fingerprint: "c".repeat(64), draft_digest: "d".repeat(64),
  review_version: 0, status: "pending", current: true, review: null,
  ...fields,
});
const envelope = (fields = {}) => ({ schema_version: 1, principal: "prn_person", scope, ...fields });

test("project navigation and context URLs preserve exact scope without accepting traversal or another endpoint", () => {
  assert.deepEqual(knowledgeScope(["chapter-one", "tenant-one", "project-one"]), scope);
  const url = new URL(knowledgeSuggestionsURL(scope, { task_id: "handoff" }), "https://host.test");
  assert.equal(url.pathname, projectKnowledgePath(scope) + "/suggestions");
  assert.equal(url.searchParams.get("task_id"), "handoff");
  const link = new URL(projectKnowledgeLink(scope, { provider: "second", candidateId: candidate().id, status: "approved" }), "https://host.test");
  assert.equal(link.searchParams.get("project"), "project-one");
  assert.equal(link.searchParams.get("knowledge"), candidate().id);
  assert.equal(link.searchParams.get("knowledge_status"), "approved");
  assert.equal(link.hash, "#knowledge-heading");
  for (const invalid of ["../other", "x/y", "https://other", ""]) assert.throws(() => knowledgeScope({ ...scope, project_id: invalid }));
  const legacy = new URL(knowledgeSuggestionsURL(scope, { task_id: "legacy:task/Équipe" }), "https://host.test");
  assert.equal(legacy.searchParams.get("task_id"), "legacy:task/Équipe");
  assert.equal(knowledgeScope({ ...scope, project_id: "legacy:project" }).project_id, "legacy:project");
  for (const invalid of [{ task_id: "\ncontrol" }, { task_id: "one", project_id: "other" }, {}, { task_id: "one", workflow_id: "two" }]) {
    assert.throws(() => knowledgeContext(invalid));
  }
});

test("responses must match both the current identity and the exact project", () => {
  assert.equal(validateKnowledgeEnvelope(envelope(), "prn_person", scope).principal, "prn_person");
  assert.throws(() => validateKnowledgeEnvelope(envelope(), "prn_other", scope));
  for (const key of Object.keys(scope)) assert.throws(() => validateKnowledgeEnvelope(envelope({ scope: { ...scope, [key]: "another" } }), "prn_person", scope));
  const otherSource = candidate({ source: { ...candidate().source, scope: { ...scope, project_id: "another" } } });
  assert.throws(() => validateKnowledgeCandidate(otherSource, scope));
  assert.throws(() => knowledgeReviewCommand(scope, otherSource, "approve", "Wrong project"));
  for (const change of [{ source_fingerprint: "unverified" }, { status: "suggested" }, { current: "true" }, { review_version: -1 }, { generator_version: 2 }, { body: null }]) {
    assert.throws(() => validateKnowledgeCandidate(candidate(change)));
  }
});

test("governance compares every displayed field, source pin, scope and review version before signing", () => {
  const item = candidate();
  const expected = knowledgeReviewCommand(scope, item, "approve", " Reviewed with the owner. ");
  assert.deepEqual(expected.payload.snapshot, knowledgeSnapshot(item));
  assert.deepEqual(expected.payload.source_fingerprint, { __bytes__: item.source_fingerprint });
  assert.equal(expected.payload.snapshot.source.evidence_digest, "b".repeat(64));
  assert.equal(expected.payload.reason, "Reviewed with the owner.");
  const core = { type: expected.type, chapter_id: scope.chapter_id, payload: expected.payload, signers: [{ key_id: "k-12345678" }] };
  const accepts = value => isExpectedCommand(value, { ...expected, keyId: "k-12345678" });
  assert.equal(accepts(core), true);
  for (const changes of [
    { candidate_id: "different" }, { project_id: "another" }, { expected_review_version: 1 },
    { draft_digest: { __bytes__: "e".repeat(64) } }, { decision: "reject" },
    { snapshot: { ...expected.payload.snapshot, body: "hidden replacement" } }, { unexpected_field: true },
  ]) assert.equal(accepts({ ...core, payload: { ...core.payload, ...changes } }), false);
  assert.equal(accepts({ ...core, chapter_id: "another" }), false);
  const request = knowledgeReviewRequest(expected, "k-12345678");
  assert.equal(request.draft_digest, item.draft_digest);
  assert.deepEqual(request.snapshot, knowledgeSnapshot(item));
  assert.equal(request.governance_key_id, "k-12345678");
});

test("rejected and withdrawn drafts require explicit reconsideration, while stale drafts cannot be approved", () => {
  for (const status of ["pending", "rejected", "withdrawn"]) {
    assert.equal(knowledgeReviewAllowed(candidate({ status }), "approve"), true);
    assert.doesNotThrow(() => knowledgeReviewCommand(scope, candidate({ status }), "approve", "Reconsidered this exact draft."));
  }
  for (const fields of [{ status: "approved" }, { status: "stale", current: false }, { status: "rejected", current: false }]) {
    assert.throws(() => knowledgeReviewCommand(scope, candidate(fields), "approve", "Review"));
  }
  assert.throws(() => knowledgeReviewCommand(scope, candidate(), "approve", ""));
  assert.throws(() => knowledgeReviewCommand(scope, candidate(), "approve", "漢".repeat(400)));
});

test("withdrawal signs the retained approved snapshot even when the original source is gone", () => {
  const original = candidate();
  const review = { event_id: "approved-01", decision: "approve", version: 1, reason: "Accepted", snapshot: knowledgeSnapshot(original),
    source_fingerprint: original.source_fingerprint, draft_digest: original.draft_digest };
  const item = candidate({ status: "stale", current: false, review_version: 1, review, source_available: false });
  const command = knowledgeReviewCommand(scope, item, "withdraw", "Source withdrawn.");
  assert.deepEqual(command.payload.snapshot, review.snapshot);
  assert.equal(command.payload.expected_review_version, 1);
  assert.equal(command.payload.decision, "withdraw");
  const changed = candidate({ review, review_version: 1, status: "pending", body: "New unapproved draft", draft_digest: "e".repeat(64), source_fingerprint: "f".repeat(64) });
  const withdrawal = knowledgeReviewCommand(scope, changed, "withdraw", "Withdraw the earlier approval.");
  assert.deepEqual(withdrawal.payload.snapshot, review.snapshot);
  assert.equal(retainedApproval(changed).body, original.body);
  assert.notEqual(withdrawal.payload.snapshot.body, changed.body);
  const foreign = { ...review, snapshot: { ...review.snapshot, source: { ...review.snapshot.source, scope: { ...scope, tenant_id: "another" } } } };
  assert.throws(() => knowledgeReviewCommand(scope, candidate({ status: "approved", review: foreign }), "withdraw", "Invalid source"));
});

test("late requests cannot restore data after hiding, revocation, identity changes or context replacement", () => {
  const reads = new KnowledgeRequests();
  const old = reads.begin("project-one/task-one");
  const replacement = reads.begin("project-one/task-one");
  assert.equal(old.controller.signal.aborted, true);
  assert.equal(reads.current(old), false);
  assert.equal(reads.current(replacement), true);
  const another = reads.begin("project-two/task-one");
  reads.clear();
  assert.equal(reads.current(replacement), false);
  assert.equal(reads.current(another), false);
  assert.equal(another.controller.signal.aborted, true);
  const fresh = reads.begin("project-one/task-one");
  assert.equal(reads.current(fresh), true);
});

test("an actual delayed JSON read is discarded even if fetch ignores cancellation", async (t) => {
  let release;
  t.mock.method(globalThis, "fetch", (_url, options) => {
    assert.equal(options.cache, "no-store");
    assert.equal(options.credentials, "same-origin");
    return new Promise(resolve => { release = resolve; });
  });
  const reads = new KnowledgeRequests();
  const pending = reads.read("queue", projectKnowledgePath(scope), "prn_person", scope);
  reads.clear();
  release({ ok: true, json: async () => envelope({ items: [candidate()] }) });
  assert.equal(await pending, null);
});

class Element {
  constructor(tag, ownerDocument) { this.tag = tag; this.ownerDocument = ownerDocument; this.children = []; this.textContent = ""; this.dataset = {}; }
  set innerHTML(_) { throw new Error("HTML injection attempted"); }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  scrollIntoView() { this.scrolled = true; }
}
const dom = { createElement: tag => new Element(tag, dom) };
const descendants = node => [node, ...node.children.filter(value => value instanceof Element).flatMap(descendants)];

test("the actual draft renderer keeps source HTML, scripts and links inert while preserving every source pin", () => {
  const root = new Element("div", dom);
  const item = candidate({ body: '<img src=x onerror="steal()">\n[run](javascript:steal())\n<script>steal()</script>', source_available: false });
  renderKnowledgeDraft(root, item);
  const nodes = descendants(root);
  assert.equal(nodes.some(node => ["img", "script", "iframe", "a"].includes(node.tag)), false);
  assert.ok(nodes.some(node => node.textContent === item.body));
  assert.ok(nodes.some(node => node.textContent.includes(item.source.completion_event_id)));
  assert.ok(nodes.some(node => node.textContent === item.draft_digest));
  assert.ok(nodes.some(node => node.textContent.includes("currently unavailable")));
  const safe = new Element("div", dom); renderKnowledgeDraft(safe, candidate(), scope);
  assert.equal(safe.children.includes(null), false);
});

test("a deep link loads its exact item even beyond the first page, with source availability shown", async (t) => {
  const oldDocument = globalThis.document;
  globalThis.document = { hidden: false };
  t.after(() => { if (oldDocument === undefined) delete globalThis.document; else globalThis.document = oldDocument; });
  const selected = candidate({ id: "task-" + "f".repeat(64), status: "approved", source_available: false });
  const items = Array.from({ length: 25 }, (_, i) => candidate({ id: "task-" + i.toString(16).padStart(64, "0"), status: "approved" }));
  const calls = [];
  t.mock.method(globalThis, "fetch", async url => {
    calls.push(url);
    const result = url.endsWith(selected.id) ? envelope({ candidate: selected }) : envelope({ items, total: 30, offset: 0, limit: 25,
      counts: { pending: 0, approved: 30, rejected: 0, withdrawn: 0, stale: 0 } });
    return { ok: true, json: async () => result };
  });
  const container = new Element("div", dom);
  const queue = new ProjectKnowledgeQueue({ container, scope, principal: () => "prn_person", canReview: () => false,
    decide: () => { throw new Error("read-only test"); }, status: "approved", selectedId: selected.id });
  await queue.refresh();
  assert.ok(calls.some(url => url === projectKnowledgePath(scope) + "/" + selected.id));
  assert.equal(queue.list.children[0].dataset.knowledgeCandidate, selected.id);
  assert.equal(queue.list.children[0].scrolled, true);
  assert.ok(descendants(queue.list.children[0]).some(node => node.textContent.includes("currently unavailable")));
  assert.equal(queue.next.disabled, false);
});

test("expanding a listed draft checks source availability through detail without changing the shown version", async (t) => {
  const oldDocument = globalThis.document;
  globalThis.document = { hidden: false };
  t.after(() => { if (oldDocument === undefined) delete globalThis.document; else globalThis.document = oldDocument; });
  const item = candidate({ status: "approved" });
  t.mock.method(globalThis, "fetch", async () => ({ ok: true, json: async () => envelope({ candidate: { ...item, source_available: false } }) }));
  const queue = new ProjectKnowledgeQueue({ container: new Element("div", dom), scope, principal: () => "prn_person", canReview: () => false, decide: () => {} });
  queue.value = { items: [item] };
  const body = new Element("div", dom);
  await queue.loadDetail(item, body);
  assert.ok(descendants(body).some(node => node.textContent.includes("currently unavailable")));
  assert.ok(descendants(body).some(node => node.textContent === item.body));
});

test("duplicate tile disclosures share one read, while clear and cancel permit a fresh context read", async (t) => {
  const oldDocument = globalThis.document;
  globalThis.document = { hidden: false };
  t.after(() => { if (oldDocument === undefined) delete globalThis.document; else globalThis.document = oldDocument; });
  const pending = [];
  t.mock.method(globalThis, "fetch", () => new Promise(resolve => pending.push(resolve)));
  const manager = new KnowledgeSuggestions({ principal: () => "prn_person" });
  const context = { task_id: "new-handoff" };
  const first = manager.disclosure(scope, context, dom);
  const duplicate = manager.disclosure(scope, context, dom);
  first.isConnected = duplicate.isConnected = true;
  const entry = [...manager.entries.values()][0];
  const oldRead = manager.load(entry);
  await manager.load(entry);
  assert.equal(pending.length, 1);

  manager.clear("Access ended.");
  const next = manager.disclosure(scope, context, dom); next.isConnected = true;
  const freshEntry = [...manager.entries.values()][0];
  const freshRead = manager.load(freshEntry);
  assert.equal(pending.length, 2);
  const response = () => ({ ok: true, json: async () => envelope({ context,
    items: [candidate({ status: "approved", reason: "From the same workflow.", score: 90 })] }) });
  pending[0](response()); await oldRead;
  assert.equal(entry.items, null);
  pending[1](response()); await freshRead;
  assert.equal(freshEntry.items.length, 1);
  assert.equal(freshEntry.loading, false);

  const laterRead = manager.load(freshEntry);
  assert.equal(pending.length, 3);
  manager.beginRender(); manager.endRender();
  const reopened = manager.disclosure(scope, context, dom); reopened.isConnected = true;
  const reopenedEntry = [...manager.entries.values()][0];
  const reopenedRead = manager.load(reopenedEntry);
  assert.equal(pending.length, 4);
  pending[2](response()); await laterRead;
  pending[3](response()); await reopenedRead;
  assert.equal(reopenedEntry.items.length, 1);
  assert.equal(reopenedEntry.loading, false);
});
