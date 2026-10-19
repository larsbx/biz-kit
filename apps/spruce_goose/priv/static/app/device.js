// This device's signing key: Ed25519, generated in the browser with
// WebCrypto as non-extractable, so script can use it but never read it out.
// Kept in IndexedDB. An administrator enrols it by naming its public key in
// the person's operator or reviewer grant; until then the ledger refuses
// what it signs.

import { hex } from "./cbor.js";

export const generate = () =>
  crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"]);

export const publicKey = async (pair) =>
  new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));

// The key ID convention the ledger's tooling uses: "k-" and the first four
// bytes of the public key.
export const keyId = (pub) => "k-" + hex(pub.subarray(0, 4));

// Whether a decoded statement is exactly this device's enrolment request: the
// enrolment schema (never a command, which carries a "type"), naming this key
// and the role asked for (operator or reviewer).
export const isOwnEnrolment = (statement, { keyId, publicKeyHex, role = "operator" }) =>
  statement?.schema === "CoopDeviceEnrolmentV1" &&
  !("type" in statement) &&
  statement.key_id === keyId &&
  statement.pubkey?.__bytes__ === publicKeyHex &&
  statement.role === role;

// Deep equality of decoded CBOR and plain values; an integer is the same
// whether decoded as a number or a BigInt.
export const same = (a, b) => {
  const int = (v) => typeof v === "bigint" || Number.isInteger(v);
  if (int(a) && int(b)) return BigInt(a) === BigInt(b);
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return a === b;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every((k) => k in b && same(a[k], b[k]));
};

// Whether a decoded command is exactly the one asked for: signed by this key
// alone, of this type, with these payload fields (compared deeply: an edited
// timing must be the one entered).
export const isExpectedCommand = (core, { keyId, type, payload }) =>
  core?.signers?.length === 1 &&
  core.signers[0].key_id === keyId &&
  core.type === type &&
  Object.entries(payload).every(([field, value]) => same(core.payload?.[field], value));

export const sign = async (pair, bytes) =>
  new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, pair.privateKey, bytes));

function request(req) {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

// The stored key pair, created on first use.
export async function load(name = "bizkit") {
  const open = indexedDB.open(name, 1);
  open.onupgradeneeded = () => open.result.createObjectStore("keys");
  const db = await request(open);
  const stored = await request(db.transaction("keys").objectStore("keys").get("device"));
  if (stored) return stored;

  const pair = await generate();
  await request(db.transaction("keys", "readwrite").objectStore("keys").put(pair, "device"));
  return pair;
}
