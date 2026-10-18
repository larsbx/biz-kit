// This device's signing key: Ed25519, generated in the browser with
// WebCrypto as non-extractable, so script can use it but never read it out.
// Kept in IndexedDB. An administrator enrols it by naming its public key in
// the person's operator grant; until then the ledger refuses what it signs.

import { hex } from "./cbor.js";

export const generate = () =>
  crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"]);

export const publicKey = async (pair) =>
  new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));

// The key ID convention the ledger's tooling uses: "k-" and the first four
// bytes of the public key.
export const keyId = (pub) => "k-" + hex(pub.subarray(0, 4));

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
