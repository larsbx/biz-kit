import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile, writeFile, mkdir, stat } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { chromium } from "playwright";
import { profile } from "../profile.mjs";
import { CREDIT_STYLE_HASH, CSP, IDS, OBSERVATION_IDS, LOAD_ID, STOP_IDS, SHELL, snapshot, capacitySnapshot, withParticipants, workFixture } from "./fixtures.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const controller = await readFile(path.resolve(here, "../../../apps/dispatch/lib/dispatch_web/controllers/fleet_map_controller.ex"), "utf8");
const policyDeclaration = controller.match(/@csp\s+([\s\S]*?)\n\s*@doc/);
assert.ok(policyDeclaration, "the production map CSP must remain inspectable");
const productionPolicy = [...policyDeclaration[1].matchAll(/"([^"\n]*)"/g)].map(match => match[1]).join("");
assert.equal(CSP, productionPolicy, "browser acceptance must use the actual production map policy");
const staticRoot = path.resolve(here, "../../../apps/dispatch/priv/static");
const artifacts = path.resolve(here, "../artifacts");
await stat(path.join(staticRoot, "vendor/cesium/index.js"));
await mkdir(artifacts, { recursive: true });
let mode = "ok";
let workMode = "ok";
let snapshotRequests = 0;
let served = () => snapshot();
const workRequests = [];
const heldWork = [];
const clients = new Map();
let coldTracking = false;
const cold = { cold_same_origin_body_bytes: 0, cold_request_count: 0 };
const MIME = { ".js": "application/javascript", ".css": "text/css", ".json": "application/json", ".jpg": "image/jpeg", ".png": "image/png", ".gif": "image/gif", ".svg": "image/svg+xml", ".wasm": "application/wasm", ".xml": "application/xml" };
function bodyBytes(value) { if (coldTracking) cold.cold_same_origin_body_bytes += Buffer.byteLength(value); return value; }
function send(value, { preserveCursor = false } = {}) {
  let first;
  for (const [client, cursor] of clients) {
    const frame = typeof value === "string" || preserveCursor ? value : { ...value, cursor: { stream_id: cursor.stream_id, sequence: ++cursor.sequence } };
    first ||= frame;
    client.write(bodyBytes(`event: dispatch-locations\ndata: ${typeof frame === "string" ? frame : JSON.stringify(frame)}\n\n`));
  }
  return first;
}
const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (coldTracking) cold.cold_request_count++;
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Content-Security-Policy", CSP);
  res.setHeader("X-Content-Type-Options", "nosniff");
  if (url.pathname === "/ui/operations/locations") {
    snapshotRequests++;
    if (["401", "403", "404"].includes(mode)) { res.writeHead(Number(mode)).end(); return; }
    if (mode === "redirect") { res.writeHead(302, { location: "/login" }).end(); return; }
    if (mode === "html") { res.writeHead(200, { "Content-Type": "text/html" }).end(bodyBytes("<html>Login</html>")); return; }
    const body = mode === "malformed" ? "{broken" : JSON.stringify(served());
    res.writeHead(200, { "Content-Type": "application/json" }).end(bodyBytes(body)); return;
  }
  if (url.pathname === "/ui/operations/locations/stream") {
    const cursor = { stream_id: randomUUID(), sequence: 0 };
    res.writeHead(200, { "Content-Type": "text/event-stream", Connection: "keep-alive" });
    res.write(bodyBytes(`event: dispatch-locations\ndata: ${JSON.stringify({ ...served(), cursor })}\n\n`));
    clients.set(res, cursor);
    req.on("close", () => clients.delete(res)); return;
  }
  const participantId = url.pathname.match(/^\/ui\/operations\/locations\/([0-9a-f-]{36})\/work$/)?.[1];
  if (participantId) {
    const observationId = req.headers["x-dispatch-observation"];
    workRequests.push({ method: req.method, participantId, observationId, pathname: url.pathname, search: url.search });
    const response = workFixture(Date.now(), participantId, observationId);
    if (workMode === "hold") { heldWork.push({ res, response }); return; }
    if (["401", "403", "404", "409", "422"].includes(workMode)) { res.writeHead(Number(workMode), { "Content-Type": "application/json" }).end(bodyBytes('{}')); return; }
    if (workMode === "scope") response.scope.key = "c".repeat(64);
    res.writeHead(200, { "Content-Type": "application/json" }).end(bodyBytes(JSON.stringify(response))); return;
  }
  if (url.pathname.startsWith("/static/")) {
    const resolved = path.resolve(staticRoot, url.pathname.slice("/static/".length));
    if (!resolved.startsWith(`${staticRoot}${path.sep}`)) { res.writeHead(404).end(); return; }
    try {
      const bytes = await readFile(resolved);
      res.writeHead(200, { "Content-Type": MIME[path.extname(resolved)] || "application/octet-stream" }).end(bodyBytes(bytes));
    } catch { res.writeHead(404).end(); }
    return;
  }
  if (url.pathname === "/operations/map") {
    // Use the production DOM. Harness import is delayed only to inspect native
    // Cesium entities/camera; the production module exports no viewer globals.
    const html = process.env.DISPATCH_GLOBE_SERVE === "1"
      ? SHELL.replace("</body>", '<script type="module" src="/static/js/maps/dispatch-map.js"></script></body>')
      : SHELL;
    res.writeHead(200, { "Content-Type": "text/html" }).end(bodyBytes(html)); return;
  }
  if (url.pathname === "/acceptance/policy") {
    res.writeHead(200, { "Content-Type": "text/html" }).end('<!doctype html><script type="module" src="/acceptance/policy.js"></script>'); return;
  }
  if (url.pathname === "/acceptance/policy.js") {
    res.writeHead(200, { "Content-Type": "application/javascript" }).end(`
      let javascriptBlocked = false;
      try { new Function("return 1")(); } catch (error) { javascriptBlocked = error.name === "EvalError"; }
      let wasmAllowed = false;
      try { await WebAssembly.compile(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])); wasmAllowed = true; } catch {}
      window.__policyProbe = { javascriptBlocked, wasmAllowed };
    `); return;
  }
  res.writeHead(404).end();
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
if (process.env.DISPATCH_GLOBE_SERVE === "1") {
  setInterval(() => send(snapshot()), 20000);
  console.log(`Synthetic browser fixture: ${origin}/operations/map`);
  await new Promise(() => {});
}
const executablePath = process.env.DISPATCH_CHROMIUM || undefined;
const browser = await chromium.launch({
  headless: true, executablePath,
  args: ["--no-sandbox", "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--enable-precise-memory-info"]
});
const viewport = { width: 1280, height: 900 };
const context = await browser.newContext({ viewport });
const external = [];
const mutations = [];
const errors = [];
const violations = [];
const assets = new Set();
await context.route("**/*", route => {
  const request = route.request();
  const url = request.url();
  if (!["GET", "HEAD"].includes(request.method())) mutations.push({ method: request.method(), url });
  if (!url.startsWith(`${origin}/`)) { external.push(url); return route.abort(); }
  assets.add(new URL(url).pathname);
  return route.continue();
});
const page = await context.newPage();
page.on("pageerror", error => errors.push(error.message));
await page.exposeFunction("recordViolation", value => violations.push(value));
await page.addInitScript(() => {
  document.addEventListener("securitypolicyviolation", event => {
    window.recordViolation({ directive: event.violatedDirective, blocked: event.blockedURI });
  });
});

async function open() {
  for (const client of clients.keys()) client.end();
  await page.goto(`${origin}/operations/map`, { waitUntil: "domcontentloaded" });
  await page.evaluate(async () => {
    const { Cesium } = await import("/static/vendor/gods-eye-view/viewer.js");
    window.__entityCollections = new Map();
    window.__lastCameraDestination = null;
    window.__observedScene = null;
    window.__renderedFrames = 0;
    const render = Cesium.CesiumWidget.prototype.render;
    Cesium.CesiumWidget.prototype.render = function (...args) {
      window.__widget = this;
      if (window.__observedScene !== this.scene) {
        window.__observedScene = this.scene;
        this.scene.postRender.addEventListener(() => window.__renderedFrames++);
      }
      return render.apply(this, args);
    };
    const add = Cesium.EntityCollection.prototype.add;
    const remove = Cesium.EntityCollection.prototype.remove;
    const removeAll = Cesium.EntityCollection.prototype.removeAll;
    Cesium.EntityCollection.prototype.add = function (entity) {
      const result = add.call(this, entity);
      if (/^[0-9a-f-]{36}$/i.test(result.id)) {
        if (!window.__entityCollections.has(this)) window.__entityCollections.set(this, new Map());
        window.__entityCollections.get(this).set(result.id, result);
      }
      return result;
    };
    Cesium.EntityCollection.prototype.remove = function (entity) {
      window.__entityCollections.get(this)?.delete(entity?.id);
      return remove.call(this, entity);
    };
    Cesium.EntityCollection.prototype.removeAll = function () {
      window.__entityCollections.get(this)?.clear();
      return removeAll.call(this);
    };
    const setView = Cesium.Camera.prototype.setView;
    Cesium.Camera.prototype.setView = function (options) {
      window.__lastCameraDestination = options?.destination;
      return setView.call(this, options);
    };
    await import("/static/js/maps/dispatch-map.js");
  });
}
const count = () => page.evaluate(() => [...window.__entityCollections.values()].reduce((sum, entries) => sum + entries.size, 0));
async function rendered(n) {
  await page.waitForFunction(expected => [...window.__entityCollections.values()].reduce((sum, entries) => sum + entries.size, 0) === expected, n);
}
async function connected() {
  for (let i = 0; i < 100; i++) {
    if (clients.size) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error("The browser did not establish an authorized stream");
}
async function selected(id = IDS[0]) {
  const index = IDS.indexOf(id);
  await page.locator("#dispatch-map-participants button").nth(index).click();
  await page.waitForFunction(() => !document.getElementById("dispatch-map-selection").hidden);
}
async function workReady() { await page.waitForFunction(() => document.querySelector("#dispatch-map-work a") !== null); }
async function waitHeld(count = 1) {
  for (let i = 0; i < 100; i++) {
    if (heldWork.length >= count) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error("Expected a pending selected-work request");
}
function releaseHeld() {
  for (const { res, response } of heldWork.splice(0)) {
    if (!res.destroyed) res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify(response));
  }
}
const checks = [];
let webgl;
let narrow;
try {
  // Exercise the real policy from a same-origin module, outside the debugger's
  // evaluation APIs and separately from the map's zero-violation assertion.
  const policyPage = await context.newPage();
  try {
    await policyPage.goto(`${origin}/acceptance/policy`);
    await policyPage.waitForFunction(() => window.__policyProbe);
    assert.deepEqual(await policyPage.evaluate(() => window.__policyProbe), {
      javascriptBlocked: true, wasmAllowed: false
    });
  } finally {
    await policyPage.close();
  }
  checks.push("a real same-origin module proves the map policy blocks both JavaScript string evaluation and WebAssembly compilation");

  coldTracking = true;
  await open(); await rendered(2); await connected();
  await page.waitForFunction(() => document.getElementById("dispatch-map-fit").disabled === false && !!window.__widget && window.__renderedFrames >= 2);
  cold.first_observation_ready_ms = Math.ceil(await page.evaluate(() => performance.now()));
  await page.waitForFunction(() => window.__renderedFrames >= 2 && window.__observedScene.globe.tilesLoaded, undefined, { timeout: 20000 });
  const projected = await page.evaluate(() => {
    const scene = window.__observedScene;
    return [...window.__entityCollections.values()].flatMap(entries => [...entries.values()].map(entity => {
      const point = scene.cartesianToCanvasCoordinates(entity.position.getValue());
      return { x: point?.x, y: point?.y, width: scene.canvas.clientWidth, height: scene.canvas.clientHeight };
    }));
  });
  assert.equal(projected.length, 2);
  assert.ok(projected.every(point => point.x >= 32 && point.x <= point.width - 32 && point.y >= 32 && point.y <= point.height - 32),
    `fit must keep both observed markers visible with margin: ${JSON.stringify(projected)}`);
  webgl = await page.locator("#dispatch-map-globe canvas").evaluate(canvas => {
    const gl = canvas.getContext("webgl2") || canvas.getContext("webgl");
    const debug = gl?.getExtension("WEBGL_debug_renderer_info");
    return { available: !!gl, width: canvas.width, height: canvas.height, lost: gl?.isContextLost(),
      renderer: debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : gl?.getParameter(gl.RENDERER) };
  });
  cold.browser_js_heap_bytes = await page.evaluate(() => performance.memory?.usedJSHeapSize ?? null);
  coldTracking = false;
  assert.equal(webgl.available, true); assert.equal(webgl.lost, false);
  assert.ok(webgl.width > 100 && webgl.height > 100);
  for (const key of ["cold_same_origin_body_bytes", "cold_request_count", "first_observation_ready_ms"]) {
    assert.ok(cold[key] <= profile.budgets[key], `${key}: ${cold[key]} exceeds ${profile.budgets[key]}`);
  }
  assert.ok(Number.isFinite(cold.browser_js_heap_bytes), "Chromium must expose measured JS heap for this controlled gate");
  assert.ok(cold.browser_js_heap_bytes <= profile.budgets.browser_js_heap_bytes);
  assert.match(await page.locator("#dispatch-map-participants").innerText(), /STALE.*MOCK/s);
  assert.equal(await page.locator("#dispatch-map-participants a").first().getAttribute("href"), `/operations/participants/${IDS[0]}`);
  await page.screenshot({ path: path.join(artifacts, "dispatch-map.png"), fullPage: true });
  checks.push("controlled cold first open meets byte/request/readiness/JS-heap budgets with actual WebGL");
  checks.push("loaded WebGL globe, visible fitted markers and accuracy/stale/mock presentation");

  await page.emulateMedia({ colorScheme: "dark" });
  assert.equal(await page.locator("body").evaluate(body => getComputedStyle(body).backgroundColor), "rgb(17, 24, 39)");
  assert.equal(await page.locator("body").evaluate(body => getComputedStyle(body).color), "rgb(243, 244, 246)");
  await page.emulateMedia({ colorScheme: "light" });
  checks.push("light and dark palettes retain explicit foreground/background contrast");

  const initialEntity = await page.evaluate(() => {
    const entity = [...window.__entityCollections.values()][0].values().next().value;
    return { constant: entity.position.isConstant, uncertainty: entity.ellipse.semiMajorAxis.getValue() };
  });
  assert.equal(initialEntity.constant, true); assert.equal(initialEntity.uncertainty, 35);
  checks.push("real Cesium positions remain constant observations with reported uncertainty");

  const styles = await page.locator("head style").allTextContents();
  assert.ok(styles.some(style => `sha256-${createHash("sha256").update(style).digest("base64")}` === CREDIT_STYLE_HASH));
  assert.equal(violations.length, 0, JSON.stringify(violations));
  checks.push("pinned credit style hash and strict production CSP without string/Wasm code generation");

  const credits = await page.locator("#dispatch-map-credits").evaluate(outer => {
    const inner = outer.querySelector(".cesium-widget-credits");
    const row = outer.getBoundingClientRect(); const content = inner.getBoundingClientRect();
    return { height: content.height, insideRow: content.top >= row.top - 1 && content.bottom <= row.bottom + 1,
      color: getComputedStyle(inner).color, rowColor: getComputedStyle(outer).color };
  });
  assert.ok(credits.height > 0 && credits.insideRow); assert.equal(credits.color, credits.rowColor);
  checks.push("visible attribution stays in its reserved row with the page foreground color");

  // Actual pick: project an observed Cesium entity, then click the canvas pixel.
  const pixel = await page.evaluate(id => {
    const widget = window.__widget;
    const entity = widget.entities.getById(id);
    const point = widget.scene.cartesianToCanvasCoordinates(entity.position.getValue());
    const bounds = widget.canvas.getBoundingClientRect();
    return { x: point.x + bounds.left, y: point.y + bounds.top };
  }, IDS[0]);
  await page.mouse.click(pixel.x, pixel.y); await workReady();
  assert.equal(await page.locator("#dispatch-map-selected-name").innerText(), "North van");
  assert.match(await page.locator("#dispatch-map-selected-position").innerText(), /47\.61000/);
  assert.equal(await page.locator("#dispatch-map-work > a").getAttribute("href"), `/operations/loads/${LOAD_ID}`);
  assert.match(await page.locator("#dispatch-map-work").innerText(), /Next stop unknown.*ordered as planned/s);
  assert.match(await page.locator("#dispatch-map-work").innerText(), /coordinates unresolved/);
  assert.equal(await page.locator("#dispatch-map-work button").count(), 1);
  assert.equal(await page.locator("#dispatch-map-work ol a").first().getAttribute("href"), `/operations/loads/${LOAD_ID}#stop-${STOP_IDS[0]}`);
  assert.equal(await page.evaluate(() => window.__widget.entities.values.filter(entity => entity.id.startsWith("stop:")).length), 1);
  await page.locator("#dispatch-map-work button").click();
  assert.equal(await page.locator("#dispatch-map-work button").getAttribute("aria-pressed"), "true");
  await page.locator("#dispatch-map-follow").click();
  await page.waitForFunction(id => window.__widget.trackedEntity?.id === id, IDS[0]);
  assert.equal(await page.locator("#dispatch-map-follow").getAttribute("aria-pressed"), "true");
  await page.screenshot({ path: path.join(artifacts, "dispatch-map-selected.png"), fullPage: true });
  checks.push("actual marker selection exposes observation-bound work, real operator/stop links and honest planned-stop state; native follow tracks that entity");

  const oldFrame = send(snapshot()); await workReady();
  const omitted = snapshot(); omitted.participants[0].position = null;
  send(omitted); await rendered(1);
  assert.equal(await page.locator("#dispatch-map-selection").isHidden(), true);
  assert.equal(await page.locator("#dispatch-map-work").innerText(), "");
  assert.equal(await page.evaluate(() => window.__widget.trackedEntity), undefined);
  assert.equal(await page.evaluate(() => window.__widget.entities.values.some(entity => entity.id.startsWith("stop:"))), false);
  send(oldFrame, { preserveCursor: true });
  await page.waitForTimeout(100);
  assert.equal(await count(), 1); assert.equal(await page.locator("#dispatch-map-selection").isHidden(), true);
  assert.match(await page.locator("#dispatch-map-participants").innerText(), /No visible location observation/);
  checks.push("observation deletion clears selection, follow, stops and work; replaying an older same-stream snapshot cannot resurrect them");

  send(snapshot()); await rendered(2);
  const rosterButton = page.locator("#dispatch-map-participants button").first();
  await rosterButton.focus();
  await page.evaluate(() => { window.__focusedRosterButton = document.activeElement; });
  send(snapshot());
  await page.waitForTimeout(5100); // Cross a real age-only refresh, not a synthetic rerender.
  assert.equal(await page.evaluate(() => document.activeElement === window.__focusedRosterButton), true);
  await page.keyboard.press("Enter"); await workReady();
  await page.locator("#dispatch-map-clear").click();
  assert.equal(await rosterButton.evaluate(button => document.activeElement === button), true);
  assert.equal(await page.locator("#dispatch-map-selection").isHidden(), true);
  checks.push("keyed keyboard controls retain focus across live and age refreshes; Enter selects and clear restores focus");

  await selected(); await workReady();
  await page.locator("#dispatch-map-filter").fill("South"); await rendered(1);
  assert.equal(await page.locator("#dispatch-map-selection").isHidden(), true);
  assert.match(await page.locator("#dispatch-map-coverage").innerText(), /1 of 2.*complete organization snapshot/);
  await page.locator("#dispatch-map-filter").fill("");
  await page.locator("#dispatch-map-location-filter").selectOption("stale"); await rendered(1);
  assert.equal(await page.locator("#dispatch-map-participants li:not([hidden]) button").innerText(), "South van");
  await page.locator("#dispatch-map-location-filter").selectOption("all"); await rendered(2);
  await page.locator("#dispatch-map-search").fill("47.61, -122.33");
  await page.locator("#dispatch-map-search-form button").click();
  assert.match(await page.locator("#dispatch-map-search-status").innerText(), /changes only the camera/);
  assert.equal(new URL(page.url()).search, "");
  await page.locator("#dispatch-map-search").fill("Seattle");
  await page.locator("#dispatch-map-search-form button").click();
  assert.match(await page.locator("#dispatch-map-search-status").innerText(), /No geocoder request was sent/);
  checks.push("local filters show complete-snapshot counts and clear excluded selection; pinned coordinate search moves only the camera without geocoding");

  const restricted = snapshot(); restricted.work_access = false;
  await selected(); await workReady();
  await page.locator("#dispatch-map-work button").click();
  send(restricted);
  await page.waitForFunction(() => document.getElementById("dispatch-map-work-status").textContent.includes("unavailable"));
  const safeCamera = await page.evaluate(() => {
    const point = window.__widget.scene.globe.ellipsoid.cartesianToCartographic(window.__lastCameraDestination);
    return { lat: point.latitude * 180 / Math.PI, lng: point.longitude * 180 / Math.PI };
  });
  assert.ok(Math.abs(safeCamera.lat - 47.61) < 0.000001 && Math.abs(safeCamera.lng + 122.33) < 0.000001);
  assert.equal(await page.locator("#dispatch-map-selection").isHidden(), false);
  assert.equal(await page.locator("#dispatch-map-work").innerText(), "");
  checks.push("work-only revocation removes stop coordinates and returns their camera view to the still-authorized observation");

  await page.locator("#dispatch-map-clear").click();
  workMode = "hold"; send(snapshot()); await selected(); await waitHeld();
  send(restricted);
  await page.waitForFunction(() => document.getElementById("dispatch-map-work-status").textContent.includes("unavailable"));
  const requestsAtRevocation = workRequests.length;
  releaseHeld(); await page.waitForTimeout(100);
  assert.equal(await page.locator("#dispatch-map-work").innerText(), "");
  assert.equal(await page.evaluate(() => window.__widget.entities.values.some(entity => entity.id.startsWith("stop:"))), false);
  assert.equal(workRequests.length, requestsAtRevocation);
  checks.push("separate work-permission removal cancels pending detail, removes stops and refuses delayed resurrection");

  // Two selected participants race; only the latest observation may render.
  await page.locator("#dispatch-map-clear").click();
  workMode = "hold"; send(snapshot()); await selected(); await waitHeld();
  await selected(IDS[1]); await waitHeld(2);
  const staleHeld = heldWork.shift();
  releaseHeld(); await workReady();
  if (!staleHeld.res.destroyed) staleHeld.res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify(staleHeld.response));
  await page.waitForTimeout(100);
  assert.equal(await page.locator("#dispatch-map-selected-name").innerText(), "South van");
  assert.match(await page.locator("#dispatch-map-selected-position").innerText(), /37\.77000/);
  assert.equal(await page.locator("#dispatch-map-work > a").count(), 1);
  assert.match(await page.locator("#dispatch-map-work > a").innerText(), /South delivery/);
  checks.push("delayed detail for a previous selection cannot replace the current participant's observation-bound result");

  for (const denied of ["403", "409", "422", "scope"]) {
    workMode = denied; await selected();
    await page.waitForFunction(() => /unavailable|observation changed|detail size limit/i.test(document.getElementById("dispatch-map-work-status").textContent));
    assert.equal(await page.locator("#dispatch-map-work").innerText(), "");
  }
  workMode = "ok";
  assert.ok(workRequests.every(request => request.method === "GET" && request.search === "" && OBSERVATION_IDS.includes(request.observationId)));
  checks.push("denied, stale-observation, oversized and wrong-scope detail fail closed; every detail request is a same-origin GET with the observation header");

  await page.locator("#dispatch-map-clear").click();
  const unsafeName = snapshot(); unsafeName.participants[0].public_name = "<img src=x onerror=alert(1)>";
  send(unsafeName); await rendered(2);
  await page.waitForFunction(() => document.querySelector("#dispatch-map-participants button").textContent.startsWith("<img"));
  assert.equal(await page.locator("#dispatch-map-participants img").count(), 0);
  assert.deepEqual(await page.evaluate(() => ({ local: localStorage.length, session: sessionStorage.length })), { local: 0, session: 0 });
  const attributes = await page.evaluate(() => [...document.querySelectorAll("*")].flatMap(node => [...node.attributes].map(attribute => attribute.value)).join("\n"));
  assert.ok(!attributes.includes("47.61") && !attributes.includes("-122.33"));
  checks.push("names remain text; private coordinates are absent from DOM attributes, URLs and browser storage");

  send(snapshot()); await rendered(2); await selected(); await workReady();
  await page.setViewportSize({ width: 390, height: 844 });
  narrow = await page.evaluate(() => ({ viewport: innerWidth, document: document.documentElement.scrollWidth,
    selectedVisible: !document.getElementById("dispatch-map-selection").hidden,
    rosterButtons: document.querySelectorAll("#dispatch-map-participants button").length }));
  assert.ok(narrow.document <= narrow.viewport, "the narrow layout must not require horizontal scrolling");
  assert.equal(narrow.selectedVisible, true); assert.equal(narrow.rosterButtons, 2);
  await page.screenshot({ path: path.join(artifacts, "dispatch-map-narrow.png"), fullPage: true });
  await page.setViewportSize(viewport);
  checks.push("390 CSS pixel emulation retains the selection, text controls and roster without horizontal overflow (not physical Android acceptance)");

  mode = "403";
  for (const client of clients.keys()) client.end();
  await rendered(0);
  assert.equal(await page.locator("#dispatch-map-participants li").count(), 0);
  assert.equal(await page.locator("#dispatch-map-selection").isHidden(), true);
  assert.equal(await page.locator("#dispatch-map-work").innerText(), "");
  assert.equal(await page.locator("#dispatch-map-search").inputValue(), "");
  await page.waitForFunction(() => document.getElementById("dispatch-map-status").textContent.includes("access is unavailable"));
  const camera = await page.evaluate(() => window.__lastCameraDestination);
  assert.ok(camera.x > 30000000 && Math.abs(camera.y) < 1 && Math.abs(camera.z) < 1);
  checks.push("disconnect clears every private view and resets the camera; revoked reconnect is terminal");

  mode = "ok"; await open(); await rendered(2); await connected();
  const wrongScope = snapshot(); wrongScope.scope.key = "d".repeat(64);
  send(wrongScope); await rendered(0);
  await page.waitForFunction(() => document.getElementById("dispatch-map-status").textContent.includes("selected access changed"));
  assert.equal(await page.locator("#dispatch-map-participants li").count(), 0);
  checks.push("a live scope replacement clears and terminates without mixing organizations");

  await open(); await rendered(2); await connected();
  send("{invalid"); await rendered(0);
  await page.waitForFunction(() => document.getElementById("dispatch-map-status").textContent.includes("could not be trusted"));
  checks.push("malformed SSE clears the real globe");

  served = () => capacitySnapshot(); await open();
  await page.waitForFunction(() => document.getElementById("dispatch-map-status").textContent.includes("size limits"));
  assert.equal(await count(), 0);
  served = () => withParticipants(snapshot(), []); await open();
  await page.waitForFunction(() => document.getElementById("dispatch-map-participants").textContent.includes("No participants"));
  assert.equal(await count(), 0);
  checks.push("capacity responses never show a partial map; complete empty scopes have an explicit text state");

  served = () => snapshot();
  for (const denial of ["401", "404", "redirect", "html"]) {
    mode = denial; await open();
    await page.waitForFunction(() => /unavailable|could not be trusted/.test(document.getElementById("dispatch-map-status").textContent));
    assert.equal(await count(), 0);
  }
  checks.push("401/404/login redirect/login HTML all fail closed");

  mode = "ok"; await open(); await rendered(2);
  await page.evaluate(() => dispatchEvent(new PageTransitionEvent("pagehide", { persisted: true })));
  assert.equal(await count(), 0);
  assert.equal(await page.locator("#dispatch-map-participants li").count(), 0);
  const beforeReload = snapshotRequests;
  mode = "404";
  await Promise.all([
    page.waitForNavigation({ waitUntil: "domcontentloaded" }),
    page.evaluate(() => dispatchEvent(new PageTransitionEvent("pageshow", { persisted: true })))
  ]);
  await page.evaluate(() => import("/static/js/maps/dispatch-map.js"));
  await page.waitForFunction(() => document.getElementById("dispatch-map-status").textContent.includes("access is unavailable"));
  assert.ok(snapshotRequests > beforeReload);
  checks.push("BFCache restore requires fresh server authorization");

  mode = "ok";
  await context.route("**/static/vendor/cesium/index.js", route => route.abort());
  await page.goto(`${origin}/operations/map`, { waitUntil: "domcontentloaded" });
  await page.evaluate(() => import("/static/js/maps/dispatch-map.js"));
  await page.waitForFunction(() => document.getElementById("dispatch-map-status").textContent.includes("globe is unavailable"));
  assert.equal(await page.locator("#dispatch-map-participants a").count(), 2);
  assert.equal(await page.locator("#dispatch-map-fit").isDisabled(), true);
  await selected(); await workReady();
  assert.equal(await page.locator("#dispatch-map-follow").isDisabled(), true);
  assert.equal(await page.locator("#dispatch-map-work button").isDisabled(), true);
  assert.equal(await page.locator("#dispatch-map-work > a").getAttribute("href"), `/operations/loads/${LOAD_ID}`);
  checks.push("renderer failure retains keyboard selection, authorized work and real record links as a complete textual fallback");

  assert.deepEqual(external, [], "the shipped globe must not contact third-party services");
  assert.deepEqual(mutations, [], "view interactions must never issue business writes");
  assert.deepEqual(errors, [], "no unhandled browser errors");
  assert.deepEqual(violations, [], "no CSP violations");
  assert.ok([...assets].some(asset => asset.includes("NaturalEarthII/") && asset.endsWith(".jpg")));
  assert.ok([...assets].some(asset => asset.includes("/Workers/")));
  checks.push("same-origin imagery/workers/assets only; selection, follow, filters and search issue no business mutations");
  const report = { passed: checks.length, checks, profile: profile.id,
    environment: { browser: await browser.version(), viewport, renderer: webgl.renderer, fixture: "loopback synthetic observations; cold fresh browser context", bodyBytes: "uncompressed HTTP response bodies including initial SSE; measured through imagery readiness", heap: "Chromium performance.memory.usedJSHeapSize, JS heap only" },
    cold, budgets: profile.budgets, webgl, narrowEmulation: { ...narrow, physicalAndroidAcceptance: false },
    creditStyleHash: CREDIT_STYLE_HASH, externalRequests: external.length, businessMutationRequests: mutations.length,
    cspViolations: violations.length, browserErrors: errors.length };
  await writeFile(path.join(artifacts, "acceptance.json"), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
} catch (error) {
  await Promise.allSettled([
    page.screenshot({ path: path.join(artifacts, "dispatch-map-failure.png"), fullPage: true }),
    writeFile(path.join(artifacts, "failure.json"), JSON.stringify({ message: error.message, stack: error.stack,
      completedChecks: checks, cold, cspViolations: violations, browserErrors: errors, externalRequests: external, mutations }, null, 2))
  ]);
  throw error;
} finally {
  await browser.close();
  releaseHeld();
  for (const client of clients.keys()) client.end();
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
