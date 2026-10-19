// The minimal web view (docs/architecture/2026-10-18-decide.md): a project's
// tasks and pending suggestions from the change feed; accept or decline,
// signed by this device's key after decoding exactly what will be signed.
//
// Opened as /app?chapter=…&tenant=…&project=… (&provider=… to choose the
// sign-in provider, default workos).

import { decode } from "./cbor.js";
import * as device from "./device.js";
import { applyFrame, base64url, describeTiming, emptyView, pendingSuggestions } from "./view.js";

const params = new URLSearchParams(location.search);
const scope = ["chapter", "tenant", "project"].map((k) => params.get(k));
const [chapter, tenant, project] = scope.map((s) => encodeURIComponent(s ?? ""));
const projectPath = `/api/v1/chapters/${chapter}/tenants/${tenant}/projects/${project}`;

const $ = (id) => document.getElementById(id);
let view = emptyView();
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

  renderDevices();
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
  const decline = el("button", { textContent: "Decline", disabled });
  accept.onclick = () => decide(s, { decision: "accept" });
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
    el("div", { className: "actions" }, accept, decline),
  );
}

// -- deciding ------------------------------------------------------------------------

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

const decide = (s, decision) =>
  signAndSubmit(
    () => postJSON(`${projectPath}/commands`, { ...decision, suggestion_event_id: s.id, key_id: keyId }),
    { type: expectedType(s, decision.decision), payload: { suggestion_event_id: s.id } },
  );

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

// Ask the server where this device stands; while a request waits for an
// administrator, ask again every ten seconds.
async function enrolment() {
  const res = await fetch(devicePath());
  if (!res.ok) return;
  const { status: state, code } = await res.json();
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
    setTimeout(enrolment, 10_000);
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

  const me = await fetch("/auth/me");
  if (!me.ok) {
    const provider = encodeURIComponent(params.get("provider") ?? "workos");
    $("who").replaceChildren(el("a", { href: `/auth/${provider}/login`, textContent: "Sign in" }));
    return status("Sign in to see this project.");
  }
  $("who").textContent = `Signed in as ${(await me.json()).principal}`;

  try {
    pair = await device.load();
    publicKey = await device.publicKey(pair);
    keyId = device.keyId(publicKey);
    publicKeyHex = Array.from(publicKey, (b) => b.toString(16).padStart(2, "0")).join("");
    $("key-id").textContent = keyId;
    $("public-key").textContent = publicKeyHex;
    $("enrol-label").value = `${navigator.platform || "This"} browser`;
    $("enrol-form").addEventListener("submit", requestAccess);
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
