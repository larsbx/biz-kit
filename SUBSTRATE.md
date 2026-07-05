# SUBSTRATE.md — Phase 1A: Canonical Signed Event Protocol + Append-Only Log

Status: Phase 1A in progress. This document is normative for the substrate. Where it deviates
from the hand-off sketch, the deviation is flagged and justified (see §2.1).

Placeholder constants are flagged **PLACEHOLDER — awaiting charter declaration** and live in
`CoopSubstrate.Constants`. None of them are real values.

---

## 1. `CoopEventCanonicalV1` — the canonical encoding profile (FROZEN)

Deterministic encoding is a protocol we own, not a library option. `CoopEventCanonicalV1` is a
strict subset of CBOR (RFC 8949) restricted to the Core Deterministic Encoding Requirements
(RFC 8949 §4.2.1), further restricted as below. Two independent implementations exist (Rust NIF
`native/canonical_v1`, production; pure-Elixir reference encoder `test/support/reference_encoder.ex`,
test-only) and MUST produce byte-identical output for every logical term; committed test vectors
in `test/vectors/` lock the profile.

### 1.1 Logical term model (what an event payload may contain)

| Logical type | Elixir representation | CBOR encoding |
|---|---|---|
| Integer | integer in `[-2^63, 2^63 - 1]` | major 0/1, shortest form |
| UTF-8 string | binary that is valid UTF-8 | major 3 (text), definite length |
| Byte string | `{:bytes, binary}` wrapper tuple | major 2 (bytes), definite length |
| Boolean | `true` / `false` | `0xf5` / `0xf4` |
| Null | `nil` | `0xf6` |
| List | list | major 4, definite length |
| Map | map with **string keys only** | major 5, definite length, sorted keys |

**Forbidden — encoders MUST reject** (`{:error, reason}`; nothing signs or hashes):

- **Floats** of any width. Money is integer minor units; decimals are scaled integers or strings.
- Integers outside `[-2^63, 2^63 - 1]` (keeps every implementation in i64; larger values are
  represented as strings at the schema layer if ever needed).
- CBOR **tags** (none allowed), indefinite-length items, `undefined`, simple values other than
  `false`/`true`/`null`.
- Atoms other than `true`/`false`/`nil`; tuples other than the `{:bytes, _}` wrapper; structs;
  any other Elixir term.
- Map keys that are not UTF-8 strings (no atom keys, no integer keys).
- Binaries that are not valid UTF-8 outside a `{:bytes, _}` wrapper (an unwrapped binary is
  *always* a text string and MUST be valid UTF-8; raw bytes MUST be wrapped).

### 1.2 Determinism rules

- **Map key ordering**: keys are sorted bytewise-lexicographically over their **encoded** key
  bytes (RFC 8949 §4.2.1). Since keys are definite-length text strings, this is length-first,
  then bytewise. Duplicate keys are impossible (Elixir maps) and are rejected by the decoder.
- **Integers**: preferred (shortest-form) encoding only; non-minimal forms are invalid.
- **Lengths**: all strings/bytes/lists/maps use definite, shortest-form length headers.
- **UTF-8**: exact bytes as provided — **no Unicode normalization** is performed or implied.
  Invalid UTF-8 in a text position is rejected. Two strings differing only in normalization form
  are *different* strings.
- **Timestamps**: one representation only — `timestamp_ms`, integer milliseconds since the Unix
  epoch, UTC. Never ISO strings, never seconds, never floats. Timestamps are author-asserted
  claims; **ordering authority is sequence, never wall-clock** (06 adversarial clock-skew;
  10 "deadlines derive from log events").
- **Size cap**: encoded output larger than `max_canonical_bytes` (65_536 bytes —
  **PLACEHOLDER — awaiting charter declaration**) is rejected. **Depth cap**: nesting deeper than
  `max_canonical_depth` (32 — **PLACEHOLDER**) is rejected. Both are enforced by both encoders
  (plain-NIF safety: bounded input, deterministic, no allocation surprises — hand-off §4).

### 1.3 Schema versioning & evolution

- Every event carries `schema_version`; the canonical profile name (`canonical_profile:
  "CoopEventCanonicalV1"`) is recorded inside the signed bytes of every event.
- **Unknown fields are rejected within a declared `schema_version`.** Evolution happens by
  declaring a new `schema_version`, never by loosening validation.
- A canonical-**profile** change (`CoopEventCanonicalV1` → `V2`) requires an explicit signed
  governance event (Phase 1D workflow; the type is representable now).
- Old events verify under their original profile/version **forever**. Immutable record,
  amendable rules — applied to the encoding itself.

### 1.4 Hashing

`hash = SHA-256(canonical_bytes)`. All hashes in the substrate (event hashes, chain links,
`auth_ref`, correction targets) are SHA-256 over `CoopEventCanonicalV1` bytes, carried as
32-byte byte strings.

---

## 2. Event Envelope V1

*(Sections below this line are completed as their build steps land; §2.1 records the signed-core
deviation from the hand-off sketch and its rationale.)*
