import test from "node:test";
import assert from "node:assert/strict";
import procurement, { validateOrigin } from "./procurement.js";

// Exercise the actual panel and API wrappers with a small DOM/IPC double.
// These are not native WebKit, TLS, or deployed-server acceptance tests.
class Element {
  constructor(tag = "text") {
    this.tag = tag; this.attrs = {}; this.children = []; this.events = {};
    this.hidden = false; this.disabled = false; this.value = ""; this.text = "";
  }
  setAttribute(k, v) { this.attrs[k] = v; }
  append(...nodes) { this.children.push(...nodes); }
  addEventListener(event, fn) { (this.events[event] ??= []).push(fn); }
  set textContent(text) { this.text = String(text); this.children = []; }
  get textContent() { return this.text + this.children.map((c) => c.textContent).join(""); }
  async click() { if (!this.disabled) for (const fn of this.events.click ?? []) await fn({ target: this }); }
}
const tick = () => new Promise((resolve) => setImmediate(resolve));
const nodes = (el) => [el, ...el.children.flatMap(nodes)];
const absent = () => ({ configured: false, origin: null, revision: "missing-v1", problem: "Add the HTTPS address of your running Procurement server." });
const configured = () => ({ configured: true, origin: "https://procurement.example.org/", revision: "existing-v1", problem: null });

async function fixture(options = {}) {
  globalThis.Node = Element;
  globalThis.document = {
    createElement: (tag) => new Element(tag),
    createTextNode: (text) => { const node = new Element(); node.textContent = text; return node; },
  };
  let connection = options.connection ?? absent();
  const calls = [], reviews = [], meta = [];
  globalThis.__TAURI__ = { core: { invoke: async (command, args) => {
    calls.push({ command, args });
    if (options.invoke) { const result = await options.invoke(command, args); if (result !== undefined) return result; }
    if (command === "procurement_status") return connection;
    if (command === "save_procurement_origin") {
      assert.equal(args.expectedRevision, connection.revision);
      connection = { configured: true, origin: args.origin, revision: "saved-v2", problem: null };
      return connection;
    }
    if (command === "open_procurement") return null;
    throw new Error(`Unexpected command ${command}`);
  } } };
  const body = new Element("section");
  const panel = procurement.mount({
    body, info: { configPath: "/test/config.json", hosts: [] }, setMeta: (text) => meta.push(text),
    confirm: async (ask) => { reviews.push(ask); if (options.cancel) return false; await ask.run(); return true; },
  });
  await tick();
  const by = (key) => nodes(body).find((e) => key in e.attrs);
  return { body, calls, reviews, meta, panel, input: nodes(body).find((e) => e.tag === "input"),
    open: by("data-procurement-open"), save: by("data-procurement-save"), reload: by("data-procurement-reload"),
    status: by("data-procurement-status"), error: nodes(body).find((e) => e.attrs.role === "alert") };
}

test("Procurement is usable without SSH hosts and has a single setup tile", () => {
  assert.equal(procurement.id, "procurement");
  assert.equal(procurement.requiresHosts, false);
  assert.equal(procurement.single, true);
});

test("missing origin shows setup rather than a dead launch button", async () => {
  const f = await fixture();
  assert.equal(f.open.disabled, true);
  assert.equal(f.input.disabled, false);
  assert.equal(f.save.disabled, false);
  assert.match(f.status.textContent, /HTTPS/);
  assert.match(f.body.textContent, /stops its test server/);
  await f.open.click();
  assert.deepEqual(f.calls.map((c) => c.command), ["procurement_status"]);
});

test("reviewed save persists via native command, then launch uses the existing opener", async () => {
  const f = await fixture();
  f.input.value = " https://procurement.example.org:8443 ";
  await f.save.click();
  assert.equal(f.reviews.length, 1);
  assert.match(f.reviews[0].command, /procurementOrigin: null/);
  assert.match(f.reviews[0].command, /https:\/\/procurement.example.org:8443\//);
  assert.deepEqual(f.calls[1], { command: "save_procurement_origin", args: { origin: "https://procurement.example.org:8443/", expectedRevision: "missing-v1" } });
  assert.equal(f.open.disabled, false);
  await f.open.click();
  assert.equal(f.calls.at(-1).command, "open_procurement");
  assert.match(f.status.textContent, /does not confirm server health/);
});

test("cancelled review neither writes settings nor opens a server", async () => {
  const f = await fixture({ cancel: true });
  f.input.value = "https://procurement.example.org";
  await f.save.click();
  assert.deepEqual(f.calls.map((c) => c.command), ["procurement_status"]);
  assert.equal(f.open.disabled, true);
});

test("configured installations keep their launch path and do not rewrite settings", async () => {
  const f = await fixture({ connection: configured() });
  assert.equal(f.input.value, configured().origin);
  assert.equal(f.open.disabled, false);
  await f.open.click();
  assert.deepEqual(f.calls.map((c) => c.command), ["procurement_status", "open_procurement"]);
});

test("unsafe or path-bearing addresses never reach save or confirmation", async () => {
  const f = await fixture();
  for (const value of ["", "http://localhost:4003", "https://user:password@example.org", "https://example.org/login", "https://example.org?", "https://example.org#", "file:///tmp", "javascript:alert(1)"]) {
    f.input.value = value;
    await f.save.click();
    assert.equal(f.error.hidden, false, value);
    assert.equal(f.reviews.length, 0, value);
  }
  assert.deepEqual(f.calls.map((c) => c.command), ["procurement_status"]);
});

test("stale save failure is visible and does not enable launch", async () => {
  const f = await fixture({ invoke: (cmd) => { if (cmd === "save_procurement_origin") throw new Error("Desktop settings changed. Reload."); } });
  f.input.value = "https://example.org";
  await f.save.click();
  assert.match(f.error.textContent, /settings changed/);
  assert.equal(f.open.disabled, true);
  assert.equal(f.reload.disabled, false);
});

test("malformed configuration disables writes and offers reload without resetting it", async () => {
  const f = await fixture({ invoke: (cmd) => { if (cmd === "procurement_status") throw new Error("Malformed config"); } });
  assert.equal(f.open.disabled, true);
  assert.equal(f.save.disabled, true);
  assert.equal(f.reload.disabled, false);
  assert.match(f.error.textContent, /Malformed/);
});

test("launch failure is visible, escaped as text, and retry remains possible", async () => {
  const f = await fixture({ connection: configured(), invoke: (cmd) => { if (cmd === "open_procurement") throw new Error("<server failure>"); } });
  await f.open.click();
  assert.equal(f.error.textContent, "<server failure>");
  assert.equal(f.error.children.length, 0);
  assert.equal(f.error.hidden, false);
  assert.equal(f.open.disabled, false);
});

test("late replies do not mutate a destroyed tile", async () => {
  let resolve;
  const f = await fixture({ invoke: (cmd) => cmd === "procurement_status" ? new Promise((ok) => { resolve = ok; }) : undefined });
  const before = f.body.textContent;
  f.panel.destroy();
  resolve(configured());
  await tick();
  assert.equal(f.body.textContent, before);
  assert.equal(f.meta.length, 0);
});

test("reload reads the new native configuration without an application restart", async () => {
  let reads = 0;
  const f = await fixture({ invoke: (cmd) => cmd === "procurement_status" ? (++reads === 1 ? absent() : configured()) : undefined });
  await f.reload.click();
  assert.equal(f.open.disabled, false);
  assert.equal(f.input.value, configured().origin);
});

test("origin normalization keeps an explicit non-default HTTPS port", () => {
  assert.equal(validateOrigin("https://Procurement.example.org:8443/"), "https://procurement.example.org:8443/");
});

test("new setup commands are registered and restricted to the main local webview", async () => {
  const { readFileSync } = await import("node:fs");
  const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
  const capability = JSON.parse(read("../../src-tauri/capabilities/default.json"));
  assert.deepEqual(capability.webviews, ["main"]);
  assert.equal(capability.remote, undefined);
  for (const command of ["procurement_status", "save_procurement_origin"]) {
    assert.ok(capability.permissions.includes("allow-" + command.replaceAll("_", "-")));
    assert.ok(read("../../src-tauri/build.rs").includes(`"${command}"`));
    assert.ok(read("../../src-tauri/src/lib.rs").includes(`procurement_settings::${command}`));
  }
});

test("native acceptance uses the visible setup controls instead of preconfigured origin", async () => {
  const { readFileSync } = await import("node:fs");
  for (const path of ["../../tests/panel-state-native.py", "../../../tests/procurement_mvp/tauri_client.py"]) {
    const source = readFileSync(new URL(path, import.meta.url), "utf8");
    assert.ok(source.includes("data-procurement-save"));
    assert.ok(source.includes(".tile-confirm .btn.go"));
    assert.ok(source.includes("data-procurement-open"));
    assert.equal(source.includes('json.dumps({"procurementOrigin": origin})'), false);
    assert.equal(source.includes('json.dumps(dict(config_data, procurementOrigin=origin))'), false);
  }
});
