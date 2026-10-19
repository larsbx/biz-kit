// The minimal web view (docs/architecture/2026-10-18-decide.md): a project's
// tasks and pending suggestions from the change feed; accept, edit then accept
// (docs/architecture/2026-10-19-amend.md), or decline; each task's next
// lifecycle step, revoking delegations, and the decided suggestions
// (docs/architecture/2026-10-19-lifecycle.md); after ready, starting,
// evidence, completion and, on a reviewer device, reviewing
// (docs/architecture/2026-10-19-execution.md); cancelling and sending back
// (docs/architecture/2026-10-19-cancel-reopen.md); and, in a browser holding
// a governance key, administration (docs/architecture/2026-10-19-administration.md).
// Everything is signed by this
// device's key after decoding exactly what will be signed.
//
// Opened as /app?chapter=…&tenant=…&project=… (&provider=… to choose the
// sign-in provider, default workos).

import { decode, hex } from "./cbor.js";
import * as device from "./device.js";
import {
  applyFrame,
  base64url,
  cancelledBecause,
  decidedSuggestions,
  describeTiming,
  emptyView,
  formTiming,
  grantFor,
  nextStep,
  otherSteps,
  pendingSuggestions,
  receiptFor,
  revocable,
  revocationType,
  timingForm,
  toReview,
} from "./view.js";

const params = new URLSearchParams(location.search);
const scope = ["chapter", "tenant", "project"].map((k) => params.get(k));
const [chapter, tenant, project] = scope.map((s) => encodeURIComponent(s ?? ""));
const projectPath = `/api/v1/chapters/${chapter}/tenants/${tenant}/projects/${project}`;

const $ = (id) => document.getElementById(id);
let view = emptyView();
let me = null;
let keyId = null;
let pair = null;
let publicKey = null;
let publicKeyHex = null;
let enrolled = false;
// Enrolled as a reviewer too: the same key, under a reviewer grant.
let reviewing = false;
// A governance key of this chapter: the same key, declared for this person.
let governing = false;
// One decision at a time: the confirmation dialog shows one command, and the
// bytes signed must be the ones it shows.
let deciding = false;

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  Object.assign(node, attrs);
  node.append(...children.filter((c) => c != null));
  return node;
}

function status(message, error = false) {
  $("status").textContent = message;
  $("status").className = error ? "status error" : "status muted";
}

async function postJSON(path, body) {
  const res = await fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json.error ?? `HTTP ${res.status}`);
  return json;
}

// -- rendering ---------------------------------------------------------------------

function render() {
  const tasks = Object.entries(view.tasks).sort(([a], [b]) => a.localeCompare(b));
  $("tasks").replaceChildren(
    ...(tasks.length
      ? tasks.map(([id, t]) =>
          el(
            "div",
            { className: "card" },
            el(
              "div",
              { className: "row" },
              el("strong", { textContent: t.title ?? id }),
              el("span", { className: "muted", textContent: t.state }),
            ),
            el("div", { className: "muted", textContent: describeTiming(t.timing) }),
            t.timing_delegation_id
              ? el("div", { className: "muted", textContent: "Last scheduled by a delegated agent" })
              : null,
            cancelledBecause(t) ? el("div", { className: "muted", textContent: cancelledBecause(t) }) : null,
            stepControl(id, t),
            otherControls(id, t),
          ),
        )
      : [el("p", { className: "muted", textContent: "None yet." })]),
  );

  const pending = pendingSuggestions(view);
  $("pending").replaceChildren(
    ...(pending.length
      ? pending.map((s) => suggestionCard(s))
      : [el("p", { className: "muted", textContent: "None." })]),
  );

  renderReviews();
  renderAdmin();
  renderDelegations();
  renderHistory();
  renderDevices();
}

// The task's next lifecycle step as a button, or what it is waiting for.
function stepControl(id, t) {
  const step = nextStep(id, view, me, keyId);
  if (!step) return null;
  if (step.evidence) {
    const submit = el("button", { textContent: step.label, disabled: !pair || !enrolled || deciding });
    submit.onclick = () => openEvidence(id, t, step.evidence);
    return el(
      "div",
      {},
      step.refused
        ? el("div", { className: "muted", textContent: `Refused by ${step.refused.principal_id}: “${step.refused.reason}”` })
        : null,
      el("div", { className: "actions" }, submit),
    );
  }
  if (step.waiting) {
    const waiting = el("span", { className: "muted", textContent: `Waiting for ${step.waiting}.` });
    if (!step.upload) return el("div", {}, waiting);
    const upload = el("button", { textContent: "Upload…", disabled: !pair || !enrolled || deciding });
    upload.onclick = () => chooseArtifact(step.upload);
    return el("div", { className: "actions" }, waiting, upload);
  }

  const { action, label, ...cites } = step;
  const button = el("button", { textContent: label, disabled: !pair || !enrolled || deciding });
  button.onclick = () =>
    signAndSubmit(
      () => postJSON(`${projectPath}/commands`, { action, task_id: id, ...cites, key_id: keyId }),
      { type: stepTypes[action], payload: { task_id: id, expected_version: t.version, ...cites } },
    );
  return el("div", { className: "actions" }, button);
}

// Cancel or send back, each with a reason, signed like any step.
function otherControls(id, t) {
  const steps = otherSteps(id, view);
  const governed = governing && !["completed", "cancelled"].includes(t.state) ? governanceCancel(id, t) : null;
  if (!steps.length && !governed) return null;
  return el(
    "div",
    { className: "actions" },
    governed,
    ...steps.map(({ action, label, question }) => {
      const button = el("button", { textContent: label, disabled: !pair || !enrolled || deciding });
      button.onclick = () => {
        const reason = prompt(question);
        if (!reason?.trim()) return;
        signAndSubmit(
          () => postJSON(`${projectPath}/commands`, { action, task_id: id, reason, key_id: keyId }),
          { type: stepTypes[action], payload: { task_id: id, expected_version: t.version, reason } },
        );
      };
      return button;
    }),
  );
}

// -- uploads (docs/architecture/2026-10-19-uploads.md) ------------------------------

const UPLOAD_LIMIT = 8 * 1024 * 1024;

// Choose a file; store it only if it is exactly the one named (its SHA-256,
// computed here); then record custody of it, signed like any command.
function chooseArtifact(expected) {
  const input = el("input", { type: "file" });
  input.onchange = () => input.files[0] && storeArtifact(input.files[0], { expected });
  input.click();
}

// Store a file and record custody of it: `{digest, receipt}`, or null with
// the reason in the status line. With `expected`, only that exact file;
// with `task`, as evidence for that task, and a receipt the project already
// holds for the same bytes is reused only after reading its verified bytes.
// A missing artifact is restored by an idempotent upload before receipt reuse.
const refused = (message) => {
  status(message, true);
  return null;
};

async function storeArtifact(file, { expected, task } = {}) {
  if (file.size > UPLOAD_LIMIT) return refused("That file is larger than 8 MiB, more than custody covers.");
  const bytes = new Uint8Array(await file.arrayBuffer());
  const digest = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)));
  if (expected && digest !== expected) return refused("That is not the file this task names; nothing was stored.");
  const held = task && receiptFor(view, digest);
  try {
    if (held) {
      status("Checking stored evidence…");
      const res = await fetch(`${projectPath}/receipts/${encodeURIComponent(held)}`);
      if (res.ok) {
        // Consume the response too: a failed transfer is not availability.
        await res.arrayBuffer();
        return { digest, receipt: held };
      }
      // Only absence is repaired; authorization and other failures remain
      // visible, and a corrupted historical artifact is never overwritten.
      if (res.status !== 404) throw new Error((await res.json().catch(() => ({}))).error ?? `HTTP ${res.status}`);
    }
    status("Storing…");
    const query = task ? `?evidence_for=${encodeURIComponent(task)}` : "";
    const res = await fetch(`${projectPath}/artifacts${query}`, {
      method: "POST",
      headers: { "content-type": "application/octet-stream", "x-content-sha256": digest },
      body: bytes,
    });
    if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error ?? `HTTP ${res.status}`);
  } catch (e) {
    return refused(`Not stored: ${e.message.replaceAll("_", " ")}.`);
  }

  if (held) return { digest, receipt: held };
  const recorded = await signAndSubmit(
    () => postJSON(`${projectPath}/commands`, { action: "record_custody", artifact_digest: digest, key_id: keyId }),
    { type: "ArtifactCustodyRecordedV1", payload: { artifact_digest: { __bytes__: digest } } },
  );
  return recorded && { digest, receipt: recorded.event_id };
}

// -- evidence and review (docs/architecture/2026-10-19-execution.md) ----------------

// One file per criterion of the Definition of Done. Each is stored and its
// custody signed, then the submission, citing exactly those receipts and
// digests.
function openEvidence(id, t, criteria) {
  $("evidence-what").textContent = `For “${t.title ?? id}”: one file for each criterion.`;
  $("evidence-error").textContent = "";
  const inputs = criteria.map((c) => el("input", { type: "file", required: true }));
  $("evidence-fields").replaceChildren(
    ...criteria.map((c, i) => el("label", {}, el("span", { textContent: c.description }), inputs[i])),
  );

  $("evidence-form").onsubmit = (event) => {
    if (event.submitter?.value !== "submit") return;
    const files = inputs.map((input) => input.files[0]);
    // Once this dialog has closed; the confirmations open next.
    setTimeout(() => submitEvidence(id, criteria, files));
  };
  $("evidence").showModal();
}

async function submitEvidence(id, criteria, files) {
  const custody_receipts = {};
  const evidence = {};
  for (const [i, c] of criteria.entries()) {
    const stored = await storeArtifact(files[i], { task: id });
    if (!stored) return;
    custody_receipts[c.id] = stored.receipt;
    evidence[c.id] = { __bytes__: stored.digest };
  }

  await signAndSubmit(
    () => postJSON(`${projectPath}/commands`, { action: "submit_evidence", task_id: id, custody_receipts, key_id: keyId }),
    { type: "TaskEvidenceSubmittedV2", payload: { task_id: id, custody_receipts, evidence } },
  );
}

// What each submission holds, fetched once per submission: null while
// loading, false if it could not be read.
const submitted = new Map();

async function loadEvidence(id, submissionId) {
  submitted.set(submissionId, null);
  const res = await fetch(`${projectPath}/tasks/${encodeURIComponent(id)}/evidence`).catch(() => null);
  const body = res?.ok ? await res.json() : null;
  // Only what is still the submission to review.
  submitted.set(submissionId, body?.submission_event_id === submissionId && body.evidence);
  render();
}

function renderReviews() {
  $("review-section").hidden = !reviewing;
  if (!reviewing) return;
  const due = toReview(view, me);
  $("reviews").replaceChildren(
    ...(due.length
      ? due.map(({ id, title, criteria, submission }) => {
          if (!submitted.has(submission.event_id)) loadEvidence(id, submission.event_id);
          const files = submitted.get(submission.event_id);
          const verdict = (decision, verb) => {
            const button = el("button", { textContent: verb, className: decision === "accept" ? "primary" : "", disabled: !pair || deciding || !files });
            button.onclick = () => {
              const reason = prompt(`Why ${decision === "accept" ? "accept" : "refuse"}? The reason is recorded on the ledger.`);
              if (reason) review(id, submission.event_id, decision, reason);
            };
            return button;
          };
          return el(
            "div",
            { className: "card" },
            el("div", {}, el("strong", { textContent: title })),
            el("div", { className: "muted", textContent: `Submitted by ${submission.principal_id}` }),
            ...criteria.map((c) => {
              const receipt = files?.[c.id]?.custody_receipt_id;
              return el(
                "div",
                { className: "row" },
                el("span", { textContent: c.description }),
                receipt
                  ? el("a", { href: `${projectPath}/receipts/${encodeURIComponent(receipt)}`, download: "", textContent: "Download" })
                  : el("span", { className: "muted", textContent: files === null ? "Loading…" : "Not available" }),
              );
            }),
            el("div", { className: "actions" }, verdict("accept", "Accept"), verdict("refuse", "Refuse")),
          );
        })
      : [el("p", { className: "muted", textContent: "None." })]),
  );
}

// Signed with this device's key under its reviewer grant, for exactly the
// submission shown.
const review = (id, submissionId, decision, reason) =>
  signAndSubmit(
    () => postJSON(`${projectPath}/commands`, { action: "review", task_id: id, decision, reason, key_id: keyId }),
    { type: "TaskDoDReviewedV1", payload: { task_id: id, submission_event_id: submissionId, decision, reason } },
  );

function renderDelegations() {
  const mine = Object.entries(view.delegations).filter(([, d]) => d.delegator_principal_id === me && d.active);
  $("delegations").replaceChildren(
    ...(mine.length
      ? mine.map(([id, d]) => {
          const revoke = el("button", { textContent: "Revoke", disabled: !pair || !enrolled || deciding });
          revoke.onclick = () =>
            confirm(`Revoke ${d.principal_id}'s delegation? It can no longer change your tasks.`) &&
            signAndSubmit(
              () => postJSON(`${projectPath}/commands`, { action: "revoke_delegation", delegation_event_id: id, key_id: keyId }),
              { type: "TaskDelegationRevokedV1", payload: { delegation_event_id: id } },
            );
          return el(
            "div",
            { className: "card row" },
            el("span", {}, el("strong", { textContent: d.principal_id }), ` may ${d.kinds.join(" and ")} · used ${d.used} of ${d.budget}`),
            revoke,
          );
        })
      : [el("p", { className: "muted", textContent: "None." })]),
  );
}

function renderHistory() {
  const decided = decidedSuggestions(view).slice(0, 20);
  $("history").replaceChildren(
    ...(decided.length
      ? decided.map((s) =>
          el(
            "div",
            { className: "card" },
            el("div", {}, el("strong", { textContent: s.status }), ` · ${s.kind === "create" ? `create “${s.change.title}”` : `reschedule ${view.tasks[s.task_id]?.title ?? s.task_id}`}`),
            el("div", { className: "muted", textContent: `Suggested by ${s.principal_id}${s.reason ? ` · “${s.reason}”` : ""}` }),
          ),
        )
      : [el("p", { className: "muted", textContent: "None yet." })]),
  );
}

function suggestionCard(s) {
  const task = view.tasks[s.task_id];
  const what =
    s.kind === "create"
      ? `Create “${s.change.title}”: ${describeTiming(s.change.timing)}`
      : `Reschedule “${task?.title ?? s.task_id}”: ${describeTiming(s.change.timing)}`;
  const stale = s.kind === "timing" && task && s.base_timing_version != null && s.base_timing_version !== task.timing_version;

  const disabled = !pair || !enrolled || deciding;
  const accept = el("button", { className: "primary", textContent: "Accept", disabled });
  const edit = el("button", { textContent: "Edit…", disabled });
  const decline = el("button", { textContent: "Decline", disabled });
  accept.onclick = () => decide(s, { decision: "accept" });
  edit.onclick = () => amend(s);
  decline.onclick = () => {
    const reason = prompt("Why decline? The reason is recorded on the ledger.");
    if (reason != null) decide(s, { decision: "decline", reason });
  };

  return el(
    "div",
    { className: "card" },
    el("div", {}, el("strong", { textContent: what })),
    el("div", { className: "muted", textContent: `Suggested by ${s.principal_id}${stale ? " · the task has changed since" : ""}` }),
    s.rationale ? el("div", { textContent: s.rationale }) : null,
    el("div", { className: "actions" }, accept, edit, decline),
  );
}

// -- deciding ------------------------------------------------------------------------

const stepTypes = {
  propose: "TaskProposedV1",
  acknowledge_sop: "TaskSOPAcknowledgedV1",
  queue: "TaskQueuedV1",
  ready: "TaskReadyV1",
  start: "TaskStartedV1",
  complete: "TaskCompletedV1",
  cancel: "TaskCancelledV1",
  reopen: "TaskReopenedV1",
};

const expectedType = (s, decision) =>
  decision === "decline" ? "TaskSuggestionDeclinedV1" : s.kind === "create" ? "TaskCreatedV1" : "TaskTimingRevisedV1";

const show = (value) =>
  JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2);

// One command at a time, through the confirmation dialog: decode what the
// server prepared, refuse unless it is exactly `expected`, show it, sign it,
// submit it (to `submitPath(prepared)`, by default the held command's path).
const commandPath = (prepared) => `/api/v1/commands/${encodeURIComponent(prepared.id)}`;

async function signAndSubmit(prepare, expected, submitPath = commandPath) {
  if (deciding) return null;
  deciding = true;
  render();

  try {
    status("Preparing…");
    const prepared = await prepare();
    const bytes = base64url.decode(prepared.signing_bytes);
    const core = decode(bytes);

    if (!device.isExpectedCommand(core, { keyId, ...expected })) {
      throw new Error("the server prepared a different command; nothing was signed");
    }

    $("confirm-body").textContent = show({ type: core.type, payload: core.payload });
    $("confirm").showModal();
    const choice = await new Promise((resolve) =>
      $("confirm").addEventListener("close", () => resolve($("confirm").returnValue), { once: true }),
    );
    if (choice !== "sign") return status("Cancelled; nothing was signed.");

    const signature = base64url.encode(await device.sign(pair, bytes));
    const result = await postJSON(submitPath(prepared), { signature });
    status(`Recorded on the ledger at #${result.global_seq}.`);
    return result;
  } catch (e) {
    status(`Not recorded: ${e.message.replaceAll("_", " ")}.`, true);
    return null;
  } finally {
    deciding = false;
    render();
  }
}

// An amended command must carry exactly the edits entered, as well as cite
// the suggestion.
const decide = (s, decision) =>
  signAndSubmit(
    () => postJSON(`${projectPath}/commands`, { ...decision, suggestion_event_id: s.id, key_id: keyId }),
    { type: expectedType(s, decision.decision), payload: { suggestion_event_id: s.id, ...decision.edits } },
  );

// -- editing before accepting ----------------------------------------------------------

const browserTz = () => {
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  return /^[A-Za-z_]+(\/[A-Za-z0-9_+-]+){0,2}$/.test(tz ?? "") ? tz : "UTC";
};

const amendFields = ["kind", "start", "end", "first", "last", "due"];

function showKind() {
  const kind = $("amend-kind").value;
  $("amend-timed").hidden = kind !== "timed";
  $("amend-all-day").hidden = kind !== "all_day";
}

// Fill the form from the suggestion; on "Review and sign", the edits go
// through the same decode, check and confirm as any decision.
function amend(s) {
  const create = s.kind === "create";
  const form = timingForm(s.change.timing);
  $("amend-what").textContent = create
    ? `Suggested by ${s.principal_id}: create “${s.change.title}”.`
    : `Suggested by ${s.principal_id}: reschedule “${view.tasks[s.task_id]?.title ?? s.task_id}”.`;
  $("amend-create").hidden = !create;
  $("amend-title").value = s.change.title ?? "";
  $("amend-description").value = s.change.description ?? "";
  for (const k of amendFields) $(`amend-${k}`).value = form[k];
  $("amend-error").textContent = "";
  showKind();

  $("amend-form").onsubmit = (event) => {
    if (event.submitter?.value !== "review") return;
    const entered = Object.fromEntries(amendFields.map((k) => [k, $(`amend-${k}`).value]));
    const { timing, error } = formTiming({ ...entered, tz: form.tz }, s.change.timing, browserTz());
    const title = $("amend-title").value.trim();
    if (error || (create && !title)) {
      event.preventDefault();
      $("amend-error").textContent = error ?? "A task needs a title.";
      return;
    }
    const description = $("amend-description").value;
    const edits = create
      ? { title, timing, ...(description || s.change.description != null ? { description } : {}) }
      : { timing };
    // Once this dialog has closed; the confirmation opens next.
    setTimeout(() => decide(s, { decision: "amend", edits }));
  };

  $("amend").showModal();
}

// -- administration (docs/architecture/2026-10-19-administration.md) ---------------
//
// Only in a browser whose key is a governance key of this chapter, declared
// for the signed-in person. Each act goes through the endpoints any holder of
// a governance key uses, and each command is signed only if it is exactly the
// one shown: these grant and end access.

const [chapterId, tenantId, projectIdRaw] = scope;

// A request signed by this browser's governance key (`Governance.Read`).
async function governed(method, path, body) {
  const authorization = await device.governanceAuthorization(pair, keyId, method, path);
  const headers = body ? { authorization, "content-type": "application/json" } : { authorization };
  const res = await fetch(path, { method, headers, body: body && JSON.stringify(body) });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(json.error ?? `HTTP ${res.status}`);
  return json;
}

const governanceSigned = (type, payload) => ({ type, payload, chapter: chapterId, exact: true });

// Cancel any task short of completed, work under way included.
function governanceCancel(id, t) {
  const button = el("button", { textContent: "Cancel as administrator…", disabled: !pair || deciding });
  button.onclick = () => {
    const reason = prompt("Why cancel this task as an administrator? The reason is recorded on the ledger, and cancelling is final.");
    if (!reason?.trim()) return;
    const path = `${projectPath}/tasks/${encodeURIComponent(id)}/cancellation`;
    signAndSubmit(
      () => governed("POST", path, { governance_key_id: keyId, reason }),
      governanceSigned("TaskCancelledByGovernanceV1", {
        tenant_id: tenantId,
        project_id: projectIdRaw,
        task_id: id,
        expected_version: t.version,
        reason,
      }),
      (prepared) => `${path}/${encodeURIComponent(prepared.id)}`,
    );
  };
  return button;
}

function renderAdmin() {
  $("admin-section").hidden = !governing;
}

const describeRequest = (d) =>
  `${d.principal_id} (signed in as ${d.identity?.subject ?? "?"} at ${d.identity?.issuer ?? "?"}) asks for ` +
  `${d.role === "governance" ? "administrator" : d.role} access` +
  `${d.role === "governance" ? ` to chapter ${d.chapter_id}` : ` to ${d.project_id}`} for “${d.label}”, key ${d.key_id}.`;

async function lookUpRequest(event) {
  event.preventDefault();
  const code = $("approve-code").value.trim().toUpperCase();
  const res = await fetch(`/api/v1/enrolments/${encodeURIComponent(code)}`);
  if (!res.ok) return $("approve-details").replaceChildren(el("p", { className: "status error", textContent: "No such request, or it has expired." }));
  const details = await res.json();
  const approve = el("button", { className: "primary", textContent: "Approve…", disabled: deciding });
  approve.onclick = async () => {
    const { type, payload } = grantFor(details);
    const path = `/api/v1/enrolments/${encodeURIComponent(code)}/approval`;
    const result = await signAndSubmit(
      () => postJSON(path, { governance_key_id: keyId }),
      { ...governanceSigned(type, payload), chapter: details.chapter_id },
      (prepared) => `${path}/${encodeURIComponent(prepared.id)}`,
    );
    if (!result) return;
    $("approve-details").replaceChildren(el("p", { className: "muted", textContent: `Approved: ${describeRequest(details)}` }));
    // A new administrator of this chapter belongs in the list at once.
    if (details.role === "governance") await loadAdministrators();
  };
  $("approve-details").replaceChildren(el("p", { textContent: describeRequest(details) }), el("div", { className: "actions" }, approve));
}

async function lookUpPerson(event) {
  event?.preventDefault();
  const id = $("person-id").value.trim();
  let found;
  try {
    found = await governed("GET", `/api/v1/principals/${encodeURIComponent(id)}`);
  } catch (e) {
    return $("person-details").replaceChildren(el("p", { className: "status error", textContent: e.message.replaceAll("_", " ") }));
  }
  const here = found.projects.find((p) => p.chapter_id === chapterId && p.tenant_id === tenantId && p.project_id === projectIdRaw);
  if (!here) return $("person-details").replaceChildren(el("p", { className: "muted", textContent: `${id} holds nothing in this project.` }));

  const rows = revocable(here.held).map((h) => {
    const revoke = el("button", { textContent: "Revoke", disabled: deciding });
    revoke.onclick = async () => {
      if (!confirm(`Revoke ${id}'s ${h.kind} device “${h.label ?? h.key_id}”?`)) return;
      const path = `/api/v1/grants/${encodeURIComponent(h.event_id)}/revocation`;
      const done = await signAndSubmit(
        () => postJSON(path, { governance_key_id: keyId }),
        governanceSigned(revocationType(h.kind), { tenant_id: tenantId, project_id: projectIdRaw, authorization_event_id: h.event_id }),
        (prepared) => `${path}/${encodeURIComponent(prepared.id)}`,
      );
      if (done) await lookUpPerson();
    };
    return el("div", { className: "row" }, el("span", { textContent: `${h.kind}: ${h.label ?? "unlabelled"} (key ${h.key_id})` }), revoke);
  });

  const offboard = el("button", { textContent: "Offboard from this project", disabled: deciding });
  offboard.onclick = async () => {
    if (!confirm(`End everything ${id} holds in this project: devices, suggester and reviewer grants, delegations?`)) return;
    const path = `/api/v1/principals/${encodeURIComponent(id)}/offboarding`;
    const done = await signAndSubmit(
      () => governed("POST", path, { governance_key_id: keyId, chapter_id: chapterId, tenant_id: tenantId, project_id: projectIdRaw }),
      governanceSigned("TaskPrincipalOffboardedV1", { tenant_id: tenantId, project_id: projectIdRaw, principal_id: id }),
      (prepared) => `${path}/${encodeURIComponent(prepared.id)}`,
    );
    if (done) await lookUpPerson();
  };

  $("person-details").replaceChildren(
    el("p", { textContent: `${id} holds ${here.held.map((h) => h.kind).join(", ")}.` }),
    ...rows,
    el("div", { className: "actions" }, offboard),
  );
}

async function loadAdministrators() {
  let keys;
  try {
    keys = await governed("GET", `/api/v1/chapters/${chapter}/administrators`);
  } catch {
    return;
  }
  $("administrators").replaceChildren(
    ...keys.map((k) => {
      const self = k.key_id === keyId;
      const revoke = el("button", { textContent: "Revoke", disabled: deciding });
      revoke.onclick = async () => {
        const reason = prompt(`Why revoke ${self ? "this browser's" : `${k.principal_id ?? "unnamed"}'s`} administrator key? Recorded on the ledger.`);
        if (!reason?.trim()) return;
        const path = `/api/v1/chapters/${chapter}/administrators/${encodeURIComponent(k.key_id)}/revocation`;
        const done = await signAndSubmit(
          () => governed("POST", path, { governance_key_id: keyId, reason }),
          governanceSigned("RoleKeyRevoked", { role: "governance", key_id: k.key_id, reason }),
          (prepared) => `${path}/${encodeURIComponent(prepared.id)}`,
        );
        if (done) await (self ? enrolment() : loadAdministrators());
      };
      return el(
        "div",
        { className: "row" },
        el("span", {}, el("strong", { textContent: k.principal_id ?? "Unnamed key" }), self ? " (this browser)" : null),
        el("span", {}, el("code", { textContent: k.key_id }), " ", revoke),
      );
    }),
  );
}

// -- devices ---------------------------------------------------------------------

let devices = [];

async function loadDevices() {
  const res = await fetch(`${projectPath}/devices`);
  devices = res.ok ? await res.json() : [];
  renderDevices();
}

function renderDevices() {
  $("devices").replaceChildren(
    ...devices.map((d) => {
      const self = d.key_id === keyId;
      const button = el("button", { textContent: self ? "Revoke this device" : "Revoke", disabled: !enrolled || deciding });
      button.onclick = () => revokeDevice(d, self);

      return el(
        "div",
        { className: "row" },
        el("span", {}, el("strong", { textContent: d.label ?? "Unnamed device" }), self ? " (this device)" : null),
        el("span", {}, el("code", { textContent: d.key_id }), " ", button),
      );
    }),
  );
}

async function revokeDevice(d, self) {
  const question = self
    ? "Revoke this device? It will no longer be able to decide for you."
    : `Revoke “${d.label ?? d.key_id}”? Do this if it is lost or you no longer use it.`;
  if (!confirm(question)) return;

  const result = await signAndSubmit(
    () => postJSON(`${projectPath}/devices/${encodeURIComponent(d.grant_id)}/revocation`, { key_id: keyId }),
    { type: "TaskDeviceRevokedV1", payload: { revoked_grant_event_id: d.grant_id } },
  );
  if (result) await enrolment();
}

// -- enrolment ---------------------------------------------------------------------

const devicePath = () => `${projectPath}/devices/${encodeURIComponent(keyId)}`;

// Ask the server where this device stands, as an operator and as a
// reviewer, and again every ten seconds while a request waits for an
// administrator, every thirty otherwise: a device can be enrolled or revoked
// from elsewhere (another browser, `mix coop.revoke`).
let enrolmentTimer = null;

const roleStatus = (role) =>
  fetch(devicePath() + (role === "operator" ? "" : `?role=${role}`))
    .then((res) => (res.ok ? res.json() : null))
    .catch(() => null);

async function enrolment() {
  clearTimeout(enrolmentTimer);
  const [operator, reviewer, governance] = await Promise.all(["operator", "reviewer", "governance"].map(roleStatus));
  const next = (ms) => (enrolmentTimer = setTimeout(enrolment, ms));
  if (!operator || !reviewer || !governance) return next(30_000);
  const { status: state, code } = operator;
  next([state, reviewer.status, governance.status].includes("pending") ? 10_000 : 30_000);
  enrolled = state === "enrolled";
  reviewing = reviewer.status === "enrolled";
  const wasGoverning = governing;
  governing = governance.status === "enrolled";

  // Offer only the roles this device has not asked for.
  const open = { operator: state === "none", reviewer: reviewer.status === "none", governance: governance.status === "none" };
  for (const option of $("enrol-role").options) option.disabled = !open[option.value];
  if (!open[$("enrol-role").value]) $("enrol-role").value = Object.keys(open).find((r) => open[r]) ?? "operator";
  $("enrol-form").hidden = !Object.values(open).some(Boolean);
  await loadDevices();
  if (governing && !wasGoverning) await loadAdministrators();

  const roleLine = (s, enrolledText, as) =>
    s.status === "enrolled"
      ? [enrolledText]
      : s.status === "pending"
        ? [`Waiting for approval as ${as}. Give your administrator this code: `, el("span", { className: "code", textContent: s.code })]
        : [];
  $("review-enrolment").replaceChildren(...roleLine(reviewer, "This device can review evidence in this project.", "a reviewer"));
  $("admin-enrolment").replaceChildren(...roleLine(governance, "This browser administers this chapter.", "an administrator"));

  if (state === "enrolled") {
    $("enrolment").textContent = "This device can decide for you in this project.";
  } else if (state === "pending") {
    $("enrolment").replaceChildren(
      "Waiting for approval. Give your administrator this code: ",
      el("span", { className: "code", textContent: code }),
    );
  } else {
    $("enrolment").textContent = "This device cannot decide yet. Request access, then give the code to your administrator.";
  }
  render();
}

async function requestAccess(event) {
  event.preventDefault();
  try {
    const role = $("enrol-role").value;
    const challenge = await postJSON(`${projectPath}/devices`, {
      key_id: keyId,
      public_key: base64url.encode(publicKey),
      label: $("enrol-label").value.trim(),
      role,
    });
    const bytes = base64url.decode(challenge.statement);

    // Prove possession by signing the enrolment statement, and nothing else.
    // (The statement names the role asked for.)
    if (!device.isOwnEnrolment(decode(bytes), { keyId, publicKeyHex, role })) {
      throw new Error("the server asked this device to sign something else; nothing was signed");
    }

    await postJSON(`/api/v1/devices/challenges/${encodeURIComponent(challenge.id)}`, {
      signature: base64url.encode(await device.sign(pair, bytes)),
    });
    await enrolment();
  } catch (e) {
    status(`Access not requested: ${e.message.replaceAll("_", " ")}.`, true);
  }
}

// -- start -------------------------------------------------------------------------

async function start() {
  if (scope.some((s) => !s)) return status("Open this page with ?chapter=…&tenant=…&project=…", true);
  $("title").textContent = `Project ${scope[2]}`;

  const signedIn = await fetch("/auth/me");
  if (!signedIn.ok) {
    const provider = encodeURIComponent(params.get("provider") ?? "workos");
    $("who").replaceChildren(el("a", { href: `/auth/${provider}/login`, textContent: "Sign in" }));
    return status("Sign in to see this project.");
  }
  me = (await signedIn.json()).principal;
  $("who").textContent = `Signed in as ${me}`;

  try {
    pair = await device.load();
    publicKey = await device.publicKey(pair);
    keyId = device.keyId(publicKey);
    publicKeyHex = Array.from(publicKey, (b) => b.toString(16).padStart(2, "0")).join("");
    $("key-id").textContent = keyId;
    $("public-key").textContent = publicKeyHex;
    // A suggestion, never over a name already typed while the page loaded.
    $("enrol-label").value ||= `${navigator.platform || "This"} browser`;
    $("enrol-form").addEventListener("submit", requestAccess);
    $("amend-kind").addEventListener("change", showKind);
    $("approve-form").addEventListener("submit", lookUpRequest);
    $("person-form").addEventListener("submit", lookUpPerson);
    await enrolment();
  } catch (e) {
    status(`This browser cannot hold a signing key (${e.message}); you can read but not decide.`, true);
  }

  follow();
}

// EventSource retries a dropped connection by itself, but gives up on an
// error response (a 401 before access is granted, a restart). Reopen then,
// with backoff, resuming from the last frame seen.
let cursor = 0;
let backoff = 1000;

function follow() {
  const feed = new EventSource(`${projectPath}/feed?cursor=${cursor}`);

  feed.addEventListener("changes", (event) => {
    view = applyFrame(view, JSON.parse(event.data));
    cursor = Number(event.lastEventId);
    backoff = 1000;
    render();
  });
  feed.onopen = () => status("Live.");
  feed.onerror = () => {
    if (feed.readyState !== EventSource.CLOSED) return status("Connection lost; reconnecting…", true);
    status("No access to this project's feed yet; retrying…", true);
    setTimeout(follow, backoff);
    backoff = Math.min(backoff * 2, 30_000);
  };
}

start();
