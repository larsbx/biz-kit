import assert from "node:assert/strict";
import { test } from "node:test";
import { TABS, initialTab } from "./hosts.js";

test("Hosts holds the four host tools as tabs, in their old sidebar order", () => {
  assert.deepEqual(TABS.map((t) => t.id), ["health", "services", "scripts", "configs"]);
  for (const t of TABS) assert.equal(typeof t.mount, "function");
});

test("the remembered tab is reopened only if it still exists", () => {
  assert.equal(initialTab("configs"), "configs");
  assert.equal(initialTab("settings"), "health");
  assert.equal(initialTab(null), "health");
});
