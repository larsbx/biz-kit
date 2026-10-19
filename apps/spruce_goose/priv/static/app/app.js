// The minimal web view (docs/architecture/2026-10-18-decide.md): a project's
// tasks and pending suggestions from the change feed; accept, edit then accept
// (docs/architecture/2026-10-19-amend.md), or decline; each task's next
// lifecycle step, revoking delegations, and the decided suggestions
// (docs/architecture/2026-10-19-lifecycle.md). Everything is signed by this
// device's key after decoding exactly what will be signed.
//
// Opened as /app?chapter=…&tenant=…&project=… (&provider=… to choose the
// sign-in provider, default workos).

import { decode, hex } from "./cbor.js";
import * as device from "./device.js";
import {
  applyFrame,
  base64url,
  decidedSuggestions,
  describeTiming,
  emptyView,
  formTiming,
  nextStep,
  pendingSuggestions,
  timingForm,
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
            stepControl(id, t),
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

  renderDelegations();
  renderHistory();
  renderDevices();
}

// The task's next lifecycle step as a button, or what it is waiting for.
function stepControl(id, t) {
  const step = nextStep(id, view, me, keyId);
  if (!step) return null;
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

// -- uploads (docs/architecture/2026-10-19-uploads.md) ------------------------------

const UPLOAD_LIMIT = 8 * 1024 * 1024;

// Choose a file; store it only if it is exactly the one named (its SHA-256,
// computed here); then record custody of it, signed like any command.
function chooseArtifact(expected) {
  const input = el("input", { type: "file" });
  input.onchange = () => input.files[0] && storeArtifact(input.files[0], expected);
  input.click();
}

async function storeArtifact(file, expected) {
  if (file.size > UPLOAD_LIMIT) return status("That file is larger than 8 MiB, more than custody covers.", true);
  const bytes = new Uint8Array(await file.arrayBuffer());
  const digest = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)));
  if (digest !== expected) return status("That is not the file this task names; nothing was stored.", true);

  try {
    status("Storing…");
    const res = await fetch(`${projectPath}/artifacts`, {
      method: "POST",
      headers: { "content-type": "application/octet-stream", "x-content-sha256": digest },
      body: bytes,
    });
    if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error ?? `HTTP ${res.status}`);
  } catch (e) {
    return status(`Not stored: ${e.message.replaceAll("_", " ")}.`, true);
  }

  await signAndSubmit(
    () => postJSON(`${projectPath}/commands`, { action: "record_custody", artifact_digest: digest, key_id: keyId }),
    { type: "ArtifactCustodyRecordedV1", payload: { artifact_digest: { __bytes__: digest } } },
  );
}

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
};

const expectedType = (s, decision) =>
  decision === "decline" ? "TaskSuggestionDeclinedV1" : s.kind === "create" ? "TaskCreatedV1" : "TaskTimingRevisedV1";

const show = (value) =>
  JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2);

// One command at a time, through the confirmation dialog: decode what the
// server prepared, refuse unless it is exactly `expected`, show it, sign it,
// submit it.
async function signAndSubmit(prepare, expected) {
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
    const result = await postJSON(`/api/v1/commands/${encodeURIComponent(prepared.id)}`, { signature });
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

// Ask the server where this device stands, and again every ten seconds while
// a request waits for an administrator, every thirty otherwise: a device can
// be enrolled or revoked from elsewhere (another browser, `mix coop.revoke`).
let enrolmentTimer = null;

async function enrolment() {
  clearTimeout(enrolmentTimer);
  const res = await fetch(devicePath()).catch(() => null);
  const next = (ms) => (enrolmentTimer = setTimeout(enrolment, ms));
  if (!res?.ok) return next(30_000);
  const { status: state, code } = await res.json();
  next(state === "pending" ? 10_000 : 30_000);
  enrolled = state === "enrolled";
  $("enrol-form").hidden = state !== "none";
  await loadDevices();

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
    const challenge = await postJSON(`${projectPath}/devices`, {
      key_id: keyId,
      public_key: base64url.encode(publicKey),
      label: $("enrol-label").value.trim(),
    });
    const bytes = base64url.decode(challenge.statement);

    // Prove possession by signing the enrolment statement, and nothing else.
    if (!device.isOwnEnrolment(decode(bytes), { keyId, publicKeyHex })) {
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
