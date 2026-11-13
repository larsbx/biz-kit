import { test } from "node:test";
import assert from "node:assert/strict";
import { leaf, split, leaves, serialize, setRatio } from "../../priv/static/app/layout.js";
import { visibleTree, chooseSection, restoreSections } from "../../priv/static/app/tiles.js";

test("unavailable sections collapse without mutating saved placement or ratios", () => {
  const tasks = leaf("tasks"), admin = leaf("admin"), reviews = leaf("reviews");
  const root = split("h", .6, tasks, split("v", .4, admin, reviews));
  const original = serialize(root);
  const view = visibleTree(root, new Set(["tasks", "reviews"]));
  assert.equal(view.b, reviews);
  assert.equal(view.r, .6);
  assert.deepEqual(serialize(root), original);
  assert.deepEqual(serialize(visibleTree(root, new Set(["tasks", "admin", "reviews"]))), original);
  assert.equal(visibleTree(root, new Set()), null);
});

test("choosing an open section exchanges positions without duplicate IDs or lost sections", () => {
  const a = leaf("tasks"), b = leaf("device");
  const root = split("h", .7, a, b);
  const next = chooseSection(root, a.id, "device");
  assert.deepEqual(leaves(next).map((l) => [l.id, l.p]), [[a.id, "device"], [b.id, "tasks"]]);
  assert.equal(next.r, .7);
  assert.equal(root.a.p, "tasks");
});

test("closed sections can replace a tile and empty splits do not duplicate content", () => {
  const a = leaf("tasks"), b = leaf("__empty__");
  const root = split("h", .5, a, b);
  const next = chooseSection(root, b.id, "tasks");
  assert.deepEqual(leaves(next).map((l) => l.p), ["__empty__", "tasks"]);
  assert.equal(chooseSection(next, b.id, "device").b.p, "device");
});

test("restore rejects duplicate real sections, unknown IDs and corrupt data", () => {
  const encode = (root) => JSON.stringify(serialize(root));
  assert.equal(restoreSections(encode(split("h", .5, leaf("tasks"), leaf("tasks"))), ["tasks"]), null);
  assert.equal(restoreSections(encode(leaf("missing")), ["tasks"]), null);
  assert.equal(restoreSections("broken", ["tasks"]), null);
  assert.ok(restoreSections(encode(split("h", .5, leaf("__empty__"), leaf("__empty__"))), []));
});

test("saved ratios and closed sections survive restoration", () => {
  const root = split("v", .5, leaf("tasks"), leaf("device"));
  const saved = JSON.stringify(serialize(setRatio(root, root.id, .72)));
  assert.deepEqual(serialize(restoreSections(saved, ["tasks", "device", "reviews"])), JSON.parse(saved));
});
