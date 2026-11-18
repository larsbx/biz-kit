import test from "node:test";
import assert from "node:assert/strict";
import { fmt, shownUnits, loopRisk } from "./services.js";
import { meterClass, pct, summarize } from "./health.js";

const U = [
  { id: "b.service", active: "active", limitUnreachable: false },
  { id: "a.service", active: "failed", limitUnreachable: false },
  { id: "z.service", active: "activating", limitUnreachable: true },
];

test("fmt", () => {
  assert.equal(fmt(Infinity), "∞");
  assert.equal(fmt(0.1), "0.1s");
  assert.equal(fmt(10), "10s");
  assert.equal(fmt(120), "2min");
});

test("loop risks sort first, then by id", () => {
  assert.deepEqual(shownUnits(U, "all", "").map((u) => u.id), ["z.service", "a.service", "b.service"]);
});

test("filters", () => {
  assert.deepEqual(shownUnits(U, "limit", "").map((u) => u.id), ["z.service"]);
  assert.deepEqual(shownUnits(U, "active", "").map((u) => u.id), ["b.service"]);
  assert.deepEqual(shownUnits(U, "all", "A.SER").map((u) => u.id), ["a.service"]);
  assert.equal(loopRisk(U), 1);
});

test("health helpers", () => {
  assert.equal(meterClass(95), "bad");
  assert.equal(meterClass(85), "warn");
  assert.equal(meterClass(10), "");
  assert.equal(pct(1, 0), 0);
  const hosts = [{ name: "a" }, { name: "b" }, { name: "c" }];
  assert.equal(summarize(hosts, { a: null, b: { reachable: true, failedUnits: ["x", "y"] } }), "3 hosts · 1 unreachable · 2 failed");
});
