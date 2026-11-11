import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile, mkdir, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { chromium } from "playwright";
import { CREDIT_STYLE_HASH, CSP, IDS, SHELL, snapshot } from "./fixtures.mjs";

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
let snapshotRequests = 0;
let served = () => snapshot();
const clients = new Set();
const MIME = { ".js": "application/javascript", ".css": "text/css", ".json": "application/json", ".jpg": "image/jpeg", ".png": "image/png", ".gif": "image/gif", ".svg": "image/svg+xml", ".wasm": "application/wasm", ".xml": "application/xml" };

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  res.setHeader("Cache-Control", "no-store");
  res.setHeader("Content-Security-Policy", CSP);
  res.setHeader("X-Content-Type-Options", "nosniff");
  if (url.pathname === "/ui/operations/locations") {
    snapshotRequests++;
    if (["401", "403", "404"].includes(mode)) { res.writeHead(Number(mode)).end(); return; }
    if (mode === "redirect") { res.writeHead(302, { location: "/login" }).end(); return; }
    if (mode === "html") { res.writeHead(200, { "Content-Type": "text/html" }).end("<html>Login</html>"); return; }
    const body = mode === "malformed" ? "{broken" : JSON.stringify(served());
    res.writeHead(200, { "Content-Type": "application/json" }).end(body); return;
  }
  if (url.pathname === "/ui/operations/locations/stream") {
    res.writeHead(200, { "Content-Type": "text/event-stream", Connection: "keep-alive" });
    res.write(": acceptance connection\n\n"); clients.add(res);
    req.on("close", () => clients.delete(res)); return;
  }
  if (url.pathname.startsWith("/static/")) {
    const resolved = path.resolve(staticRoot, url.pathname.slice("/static/".length));
    if (!resolved.startsWith(`${staticRoot}${path.sep}`)) { res.writeHead(404).end(); return; }
    try {
      const bytes = await readFile(resolved);
      res.writeHead(200, { "Content-Type": MIME[path.extname(resolved)] || "application/octet-stream" }).end(bytes);
    } catch { res.writeHead(404).end(); }
    return;
  }
  if (url.pathname === "/operations/map") {
    // The exact production DOM contract; app import is delayed by the harness
    // solely so it can observe actual Cesium entity lifetimes in this browser.
    const html = process.env.DISPATCH_GLOBE_SERVE === "1"
      ? SHELL.replace("</body>", '<script type="module" src="/static/js/maps/dispatch-map.js"></script></body>')
      : SHELL;
    res.writeHead(200, { "Content-Type": "text/html" }).end(html); return;
  }
  res.writeHead(404).end();
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
if (process.env.DISPATCH_GLOBE_SERVE === "1") {
  setInterval(() => {
    for (const client of clients) client.write(`event: dispatch-locations\ndata: ${JSON.stringify(snapshot())}\n\n`);
  }, 20000);
  console.log(`Synthetic browser fixture: ${origin}/operations/map`);
  await new Promise(() => {});
}
const executablePath = process.env.DISPATCH_CHROMIUM || undefined;
const browser = await chromium.launch({
  headless: true, executablePath,
  args: ["--no-sandbox", "--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"]
});
const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
const external = [];
const errors = [];
const violations = [];
const assets = new Set();
await context.route("**/*", route => {
  const url = route.request().url();
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
  for (const client of clients) client.end();
  await page.goto(`${origin}/operations/map`, { waitUntil: "domcontentloaded" });
  await page.evaluate(async () => {
    // These observations are test-only. Production exports no viewer global,
    // participant collection, coordinates or diagnostic snapshot.
    const { Cesium } = await import("/static/vendor/gods-eye-view/viewer.js");
    window.__entityCollections = new Map();
    window.__lastCameraDestination = null;
    const add = Cesium.EntityCollection.prototype.add;
    const removeAll = Cesium.EntityCollection.prototype.removeAll;
    Cesium.EntityCollection.prototype.add = function (entity) {
      const result = add.call(this, entity);
      if (/^[0-9a-f-]{36}$/i.test(result.id)) {
        if (!window.__entityCollections.has(this)) window.__entityCollections.set(this, new Map());
        window.__entityCollections.get(this).set(result.id, result);
      }
      return result;
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
function send(value) {
  for (const client of clients) client.write(`event: dispatch-locations\ndata: ${typeof value === "string" ? value : JSON.stringify(value)}\n\n`);
}

const checks = [];
try {
  await open(); await rendered(2);
  await page.waitForFunction(() => document.getElementById("dispatch-map-fit").disabled === false);
  assert.match(await page.locator("#dispatch-map-participants").innerText(), /STALE.*MOCK/s);
  assert.equal(await page.locator("#dispatch-map-participants a").first().getAttribute("href"), `/operations/participants/${IDS[0]}`);
  const webgl = await page.locator("#dispatch-map-globe canvas").evaluate(canvas => {
    const gl = canvas.getContext("webgl2") || canvas.getContext("webgl");
    return { available: !!gl, width: canvas.width, height: canvas.height, lost: gl?.isContextLost() };
  });
  assert.equal(webgl.available, true); assert.equal(webgl.lost, false);
  assert.ok(webgl.width > 100 && webgl.height > 100);
  await page.screenshot({ path: path.join(artifacts, "dispatch-map.png"), fullPage: true });
  checks.push("real WebGL globe and observed accuracy/stale/mock presentation");

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
  checks.push("real Cesium positions are constant observations with reported accuracy");

  const styles = await page.locator("head style").allTextContents();
  assert.ok(styles.some(style => `sha256-${createHash("sha256").update(style).digest("base64")}` === CREDIT_STYLE_HASH));
  assert.equal(violations.length, 0, JSON.stringify(violations));
  checks.push("pinned credit style hash and strict production CSP");

  const omitted = snapshot(); omitted.participants[0].position = null;
  send(omitted); await rendered(1);
  assert.match(await page.locator("#dispatch-map-participants").innerText(), /No visible location observation/);
  checks.push("null position removes its previous globe entity");

  const unsafeName = snapshot(); unsafeName.participants[0].public_name = "<img src=x onerror=alert(1)>";
  send(unsafeName); await rendered(2);
  await page.waitForFunction(() => document.querySelector("#dispatch-map-participants a").textContent.startsWith("<img"));
  assert.equal(await page.locator("#dispatch-map-participants img").count(), 0);
  assert.deepEqual(await page.evaluate(() => ({ local: localStorage.length, session: sessionStorage.length })), { local: 0, session: 0 });
  const attributes = await page.evaluate(() => [...document.querySelectorAll("*")].flatMap(node => [...node.attributes].map(attribute => attribute.value)).join("\n"));
  assert.ok(!attributes.includes("47.61") && !attributes.includes("-122.33"));
  checks.push("names remain text; coordinates absent from attributes, URLs and browser storage");

  mode = "403";
  for (const client of clients) client.end();
  await rendered(0);
  assert.equal(await page.locator("#dispatch-map-participants li").count(), 0);
  await page.waitForFunction(() => document.getElementById("dispatch-map-status").textContent.includes("access is unavailable"));
  const camera = await page.evaluate(() => window.__lastCameraDestination);
  assert.ok(camera.x > 30000000 && Math.abs(camera.y) < 1 && Math.abs(camera.z) < 1);
  checks.push("disconnect immediately clears entities/list/camera; revoked reconnect is terminal");

  mode = "ok"; await open(); await rendered(2);
  send("{invalid"); await rendered(0);
  await page.waitForFunction(() => document.getElementById("dispatch-map-status").textContent.includes("could not be trusted"));
  checks.push("malformed SSE clears the real globe");

  served = () => ({ ...snapshot(), status: "capacity_exceeded", participants: [] });
  await open();
  await page.waitForFunction(() => document.getElementById("dispatch-map-status").textContent.includes("200-participant"));
  assert.equal(await count(), 0);
  checks.push("capacity response never shows a partial map");

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
  // The fixture intentionally loads the entry via the harness; a real server
  // document loads it with its script tag after this fresh navigation.
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
  checks.push("renderer asset failure retains the authorized textual view without an unhandled rejection");

  assert.deepEqual(external, [], "the shipped globe must not contact third-party services");
  assert.deepEqual(errors, [], "no unhandled browser errors");
  assert.deepEqual(violations, [], "no CSP violations");
  assert.ok([...assets].some(asset => asset.includes("NaturalEarthII/") && asset.endsWith(".jpg")));
  assert.ok([...assets].some(asset => asset.includes("/Workers/")));
  checks.push("same-origin imagery, workers and assets only");
  console.log(JSON.stringify({ passed: checks.length, checks, webgl, creditStyleHash: CREDIT_STYLE_HASH, externalRequests: external.length, cspViolations: violations.length, browserErrors: errors.length }, null, 2));
} finally {
  await browser.close();
  for (const client of clients) client.end();
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
