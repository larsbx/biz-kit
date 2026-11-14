import test from "node:test";
import assert from "node:assert/strict";
import { httpsOrigin, readConnection, saveConnection } from "./procurement-connection.js";

test("HTTPS origins normalize without guessing a backend", () => {
  assert.equal(httpsOrigin(" https://procurement.example.org:8443/ "), "https://procurement.example.org:8443");
  assert.equal(httpsOrigin("https://EXAMPLE.org:443/"), "https://example.org");
});
for (const raw of ["", "http://localhost", "https://user:pass@p.test", "https://p.test/login", "https://p.test/?token=x", "https://p.test/#x", "file:///tmp/a"]) {
  test(`rejects unsafe or ambiguous server ${JSON.stringify(raw)}`, () => assert.throws(() => httpsOrigin(raw)));
}
test("native write binds the reviewed revision and changes no other setting", async () => {
  const calls = [];
  globalThis.__TAURI__ = { core: { invoke: async (...args) => { calls.push(args); return { origin: "https://p.test" }; } } };
  try {
    await readConnection(); await saveConnection("https://p.test", "sha256:fixture");
    assert.deepEqual(calls, [["procurement_connection", undefined], ["save_procurement_connection", {origin: "https://p.test", expectedRevision: "sha256:fixture"}]]);
  } finally { delete globalThis.__TAURI__; }
});
test("no web fallback or simulated success outside the desktop", () => {
  assert.throws(readConnection, /Only in the desktop/);
});
