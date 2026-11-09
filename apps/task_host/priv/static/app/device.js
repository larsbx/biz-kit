// This device's signing key: Ed25519, generated in the browser with
// WebCrypto as non-extractable, so script can use it but never read it out.
// Kept in IndexedDB. An administrator enrols it by naming its public key in
// the person's operator or reviewer grant; until then the ledger refuses
// what it signs.

import { encode, hex } from "./cbor.js";
import { base64url } from "./view.js";

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
// timing must be the one entered). With `exact`, the payload must be exactly
// `payload`, and with `chapter`, for that chapter: what an administrator
// signs grants or ends access, so nothing else may ride along.
export const isExpectedCommand = (core, { keyId, type, payload, chapter, exact = false }) =>
  core?.signers?.length === 1 &&
  core.signers[0].key_id === keyId &&
  core.type === type &&
  (chapter === undefined || core.chapter_id === chapter) &&
  (exact
    ? same(core.payload, payload)
    : Object.entries(payload).every(([field, value]) => same(core.payload?.[field], value)));

// A batch held as one (an offboarding from a chapter): exactly the commands
// shown, each exactly, each once, in whatever order the server holds them.
export const isExpectedBatch = (cores, { keyId, chapter, commands }) => {
  const matches = (core, c) => isExpectedCommand(core, { keyId, chapter, exact: true, ...c });
  return (
    cores.length === commands.length &&
    commands.every((c) => cores.filter((core) => matches(core, c)).length === 1) &&
    cores.every((core) => commands.some((c) => matches(core, c)))
  );
};

// What a governance-signed read signs (`Governance.Read`): the request, never
// a command, canonically encoded.
export const governanceReadBytes = ({ method, path, timestamp_ms, nonce, key_id }) =>
  encode({ schema: "CoopGovernanceReadV1", method, path, timestamp_ms, nonce, key_id });

// The Authorization header for a request signed by this browser's governance
// key (docs/architecture/2026-10-19-administration.md).
export async function governanceAuthorization(pair, keyId, method, path, now = Date.now()) {
  const nonce = base64url.encode(crypto.getRandomValues(new Uint8Array(18)));
  const bytes = governanceReadBytes({ method, path, timestamp_ms: now, nonce, key_id: keyId });
  const sig = base64url.encode(await sign(pair, bytes));
  return `CoopGovernance key="${keyId}", ts="${now}", nonce="${nonce}", sig="${sig}"`;
}

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
