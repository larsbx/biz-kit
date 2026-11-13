import assert from "node:assert/strict";
import { test } from "node:test";
import {
  PRESETS, closeLeaf, currentPreset, layoutFrames, leaf, leaves, parseLayout, reconcile,
  retainPanels, serialize, setPanel, setRatio, split, splitLeaf,
} from "./layout.js";
import { placement, samePlace } from "../panels/operations.js";

const ids = (n) => leaves(n).map((l) => l.id);
const panels = (n) => leaves(n).map((l) => l.p);
const ALL = new Set(["operations", "dispatch", "procurement", "hosts"]);

test("splitting keeps the split tile's identity and adds one new leaf", () => {
  const a = leaf("health");
  const root = splitLeaf(a, a.id, "h", "services");
  assert.equal(root.t, "split");
  assert.equal(root.a, a);
  assert.deepEqual(panels(root), ["health", "services"]);
});

test("closing gives the space to the sibling; the last tile stays", () => {
  const a = leaf("health"), b = leaf("services");
  const root = split("h", 0.5, a, b);
  assert.equal(closeLeaf(root, a.id), b);
  assert.equal(closeLeaf(b, b.id), b);
});

test("surviving tiles keep their leaf ids through split, close, resize and preset changes", () => {
  const a = leaf("operations"), b = leaf("hosts"), c = leaf("dispatch");
  let root = split("h", 0.5, a, split("v", 0.5, b, c));
  root = setRatio(root, root.id, 0.7);
  assert.deepEqual(ids(root), [a.id, b.id, c.id]);
  root = closeLeaf(root, b.id);
  assert.deepEqual(ids(root), [a.id, c.id]);
  root = retainPanels(PRESETS.find((p) => p.name === "Dispatch desk").build(), root);
  // Dispatch desk = dispatch | operations: both live instances are reused.
  assert.deepEqual(ids(root), [c.id, a.id]);
});

test("replacing a tile's panel gives it a new id, so the old panel is destroyed", () => {
  const a = leaf("health");
  const next = setPanel(a, a.id, "operations");
  assert.notEqual(next.id, a.id);
  assert.deepEqual(reconcile([a.id], next), { mount: [next.id], keep: [], destroy: [a.id] });
});

test("reconcile mounts new leaves, keeps survivors and destroys the rest", () => {
  const a = leaf("health"), b = leaf("services");
  const root = split("h", 0.5, a, leaf("configs"));
  const plan = reconcile([a.id, b.id], root);
  assert.deepEqual(plan.keep, [a.id]);
  assert.deepEqual(plan.destroy, [b.id]);
  assert.equal(plan.mount.length, 1);
});

test("duplicate panels are retained one instance each, in reading order", () => {
  const s1 = leaf("services"), s2 = leaf("services");
  const current = split("h", 0.5, s1, s2);
  const next = retainPanels(split("v", 0.5, leaf("services"), leaf("services")), current);
  assert.deepEqual(ids(next), [s1.id, s2.id]);
});

test("a stored layout round-trips, and anything malformed or unknown is refused whole", () => {
  for (const p of PRESETS) {
    const back = parseLayout(JSON.stringify(serialize(p.build())), ALL);
    assert.equal(currentPreset(back), p.name);
  }
  assert.equal(parseLayout(JSON.stringify({ t: "leaf", p: "settings" }), ALL), null);
  assert.equal(parseLayout(JSON.stringify({ t: "split", dir: "x", r: 0.5, a: { t: "leaf", p: "health" }, b: { t: "leaf", p: "health" } }), ALL), null);
  assert.equal(parseLayout("{not json", ALL), null);
  assert.equal(parseLayout(null, ALL), null);
  const clamped = parseLayout(JSON.stringify({ t: "split", dir: "h", r: 5, a: { t: "leaf", p: "hosts" }, b: { t: "leaf", p: "dispatch" } }), ALL);
  assert.equal(clamped.r, 0.85);
});

test("every preset names only registered panels, and the default leads with Operations", () => {
  for (const p of PRESETS) for (const id of panels(p.build())) assert.ok(ALL.has(id), `${p.name}: ${id}`);
  assert.equal(panels(PRESETS[0].build())[0], "operations");
});

test("a layout saved before Hosts merged its four panels falls back to the default", () => {
  const old = JSON.stringify({ t: "split", dir: "h", r: 0.36, a: { t: "leaf", p: "health" }, b: { t: "leaf", p: "services" } });
  assert.equal(parseLayout(old, ALL), null);
});

test("resizing keeps the preset mark; a split clears it", () => {
  const root = PRESETS[0].build();
  assert.equal(currentPreset(setRatio(root, root.id, 0.6)), PRESETS[0].name);
  const l = leaves(root)[0];
  assert.equal(currentPreset(splitLeaf(root, l.id, "v", "configs")), null);
});

test("frames account for the 12px gap before sharing space", () => {
  const root = split("h", 0.25, leaf("health"), leaf("services"));
  const { panels: frames, splits } = layoutFrames(root);
  assert.equal(splits.length, 1);
  assert.match(frames[0].style, /width:calc\(25% \+ -3px\)/);
  assert.match(frames[1].style, /left:calc\(25% \+ 9px\)/);
  assert.match(frames[1].style, /width:calc\(75% \+ -9px\)/);
});

test("the Operations webview hides when covered, disconnected or collapsed", () => {
  const rect = { left: 10.4, top: 20.6, width: 300.2, height: 200.5 };
  assert.deepEqual(placement(rect, { covered: false, connected: true }), { x: 10, y: 21, w: 300, h: 201 });
  assert.equal(placement(rect, { covered: true, connected: true }), null);
  assert.equal(placement(rect, { covered: false, connected: false }), null);
  assert.equal(placement({ left: 0, top: 0, width: 0, height: 0 }, { covered: false, connected: true }), null);
  assert.ok(samePlace(null, null));
  assert.ok(!samePlace(null, { x: 0, y: 0, w: 1, h: 1 }));
});
