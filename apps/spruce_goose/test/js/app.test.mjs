// The web view's pure modules, against the ledger's own committed vectors
// (apps/coop_substrate/test/vectors). Run: node --test apps/spruce_goose/test/js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import { decode, hex } from "../../priv/static/app/cbor.js";
import { sign, keyId } from "../../priv/static/app/device.js";
import { applyFrame, emptyView, pendingSuggestions, base64url } from "../../priv/static/app/view.js";

const vectors = JSON.parse(
  readFileSync(new URL("../../../coop_substrate/test/vectors/canonical_v1_vectors.json", import.meta.url))
);

const fromHex = (h) => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));

// JSON numbers lose precision past 2^53; compare BigInts as numbers the same way.
const comparable = (v) =>
  typeof v === "bigint"
    ? Number(v)
    : Array.isArray(v)
      ? v.map(comparable)
      : v && typeof v === "object"
        ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, comparable(x)]))
        : v;

test("decodes every committed vector to its logical term", () => {
  for (const v of vectors.vectors) {
    assert.deepEqual(comparable(decode(fromHex(v.canonical_hex))), v.term, v.name);
  }
});

test("keeps integers past 2^53 exact", () => {
  // -2^63 and 2^63 - 1
  assert.equal(decode(fromHex("3b7fffffffffffffff")), -(2n ** 63n));
  assert.equal(decode(fromHex("1b7fffffffffffffff")), 2n ** 63n - 1n);
  assert.equal(decode(fromHex("1b001fffffffffffff")), 2 ** 53 - 1);
});

test("refuses what the profile forbids", () => {
  for (const [what, h] of [
    ["float", "f93c00"],
    ["tag", "c11a514b67b0"],
    ["indefinite array", "9f01ff"],
    ["trailing bytes", "0101"],
    ["truncated", "62ab"],
    ["integer map key", "a10102"],
    ["invalid UTF-8", "61ff"],
  ]) {
    assert.throws(() => decode(fromHex(h)), /not CoopEventCanonicalV1/, what);
  }
});

test("the browser's Ed25519 signature is the ledger's, byte for byte", async () => {
  // PKCS#8 wrapping of a raw Ed25519 seed (RFC 8410).
  const pkcs8 = fromHex("302e020100300506032b657004220420" + vectors.ed25519_seed_hex);
  const privateKey = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, false, ["sign"]);

  for (const v of vectors.vectors) {
    assert.equal(hex(await sign({ privateKey }, fromHex(v.canonical_hex))), v.sig_hex, v.name);
  }
});

test("key IDs follow the ledger's convention", () => {
  assert.equal(keyId(fromHex(vectors.ed25519_pubkey_hex)), "k-" + vectors.ed25519_pubkey_hex.slice(0, 8));
});

test("frames build the view; suggestions filter to pending", () => {
  const view = [
    { seq: 3, changes: [{ kind: "tasks", id: "t1", value: { title: "A" } }] },
    {
      seq: 5,
      changes: [
        { kind: "suggestions", id: "s1", value: { status: "pending", task_id: "t1" } },
        { kind: "suggestions", id: "s2", value: { status: "accepted", task_id: "t1" } },
        { kind: "tasks", id: "t1", value: { title: "B" } },
      ],
    },
  ].reduce(applyFrame, emptyView());

  assert.deepEqual(view.tasks, { t1: { title: "B" } });
  assert.deepEqual(pendingSuggestions(view), [{ id: "s1", status: "pending", task_id: "t1" }]);
});

test("base64url round-trips without padding", () => {
  const bytes = Uint8Array.from({ length: 65 }, (_, i) => (i * 37) % 256);
  const text = base64url.encode(bytes);
  assert.doesNotMatch(text, /[+/=]/);
  assert.deepEqual(base64url.decode(text), bytes);
});
