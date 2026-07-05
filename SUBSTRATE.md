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

Implemented by `CoopSubstrate.Protocol.Envelope`; types declared in
`CoopSubstrate.Protocol.TypeRegistry`.

### 2.1 Signed-core deviation from the hand-off sketch (flagged; spec-forced)

The hand-off sketch (docs/handoff.md §1.6) places `prev_global_hash`/`global_seq` **inside** the
signed bytes. That is incompatible with spec-mandated bilateral/asynchronous dual signing
(05 §1.2, 07 §3, 08 §8): a counterparty cannot sign a global chain position that is only assigned
at append — the position does not exist when they sign. Resolution is certificate-transparency-
shaped: **authors vouch for content; the log vouches for position.**

- **Signed core** (what every signer signs — one canonical map, sig-excluded):
  `auth_ref?`, `canonical_profile`, `chapter_id`, `event_id` (ULID), `payload`,
  `schema_version`, `signers` (ordered, role-tagged `{key_id, pubkey, role}`), `timestamp_ms`,
  `type`. Stream identity is derivable from `type` + `payload` + `chapter_id` (08 §1, 07 P7), so
  signers bind to the stream implicitly; it is never author-supplied. `auth_ref` is an optional
  32-byte hash-pointer to the authorizing event (10 P1 provenance; required-per-type later).
- **Signature set**: stored beside the core, never inside the signed bytes. All signers sign the
  same sig-excluded canonical bytes; signatures may be produced out of order and attached
  asynchronously (`attach_signature/3` verifies before storing — invalid signatures are never
  held). Completeness = every registry-declared role signed. Witness attestations are separate
  events referencing the event hash, not extra signers.
- **Log-assigned at append** (never signed by authors): `stream_id`, `stream_seq`, `global_seq`,
  `prev_stream_hash`, `prev_global_hash`.
- **`event_hash`** = SHA-256 over the canonical encoding of the **full record** (core + ordered
  signature set + chain fields), so the dual chains are tamper-evident over signatures and
  positions too. Chains: global (whole log) + per-stream.
- Author authenticity = signatures over the core; history integrity = dual hash-chains; future
  checkpoints (Phase 1D) sign chain heads. Timestamps remain author-asserted claims; ordering
  authority is sequence, never wall-clock.

### 2.2 Type registry (minimal for 1A)

Per type (pure data, no functions — so registration can later be gated by prior log events,
09 gated-N, without rework; `validity_check/2` is the stub hook):

- `payload` schema — required/optional fields with type checkers
  (`:string | :int | :bytes | :hash | :pubkey | :bool | :any`); unknown fields rejected (§1.3).
- `required_roles` — the signer roles that must be declared and must all sign (declared roles
  must equal required roles exactly; extra roles rejected).
- `stream` — assignment rule: `{:chapter_scoped, prefix}` → `<chapter_id>/<prefix>`, or
  `{:payload_field, prefix, field}` → `<chapter_id>/<prefix>/<payload[field]>`.
- `disclosure_class` — `:commons | :telemetry | :edges` (08 §5); carried as data in 1A,
  enforced by later phases.

Bootstrap types shipped in 1A: `TestProjectionEvent`, `CorrectionRecorded` (payload:
`target_event_hash`, `reason`), `KeyRotated` (payload: `member_id`, `old_key_id`, `new_key_id`,
`new_pubkey`), `CharterConstantDeclared` (payload: `name`, `value`, `note?`). Governance
semantics for the latter three are Phase 1D; representability is the 1A criterion.

`chapter_id` is required on every event. Federation-scoped events (09 §1) are an **open
representation question** — not resolved in 1A.

### 2.3 Signing & verification rules

- Sign: Ed25519 over `Canonical.encode(signed_core_term)`; verification re-encodes the
  sig-excluded core and checks every declared signer's signature (missing or invalid → reject,
  identifying the `key_id`).
- `Envelope.new/1` validates before anything signs: registered type, payload schema, signer-set
  shape and role match, `chapter_id`/ULID/timestamp/auth_ref shape, and canonical encodability
  of the core (size/depth caps bite here).
- Boot self-test (`CoopSubstrate.SelfTest`): `:eddsa` support, RFC 8032 §7.1 TEST 1, and the
  committed `envelope-core` vector re-encoded through the production NIF, hashed, and
  signature-verified — any mismatch aborts boot.

## 3. Event store decision — Commanded `eventstore`, after an honest AshEvents spike

Hand-off §1.7 makes AshEvents (0.7.0, on Ash 3.29.x) the *default* choice but requires a spike
answering five questions (plus atomic multi-event append, added by the plan for 06 P3 batch
semantics) before committing to it. The spike lives at `spikes/ash_events_spike/`
(`mix run spike_run.exs` reproduces every finding empirically; kept as documentation).

### 3.1 Spike findings (AshEvents 0.7.0)

| # | Question (hand-off §1.7) | Finding | Verdict |
|---|---|---|---|
| Q1 | Enforce append-only? | The event-log resource exposes only `create` and `replay` actions (no update/destroy at the Ash layer), but there is **no DB-level protection**: raw SQL `UPDATE`/`DELETE` against the `events` table succeeds. Append-only is a convention of the Ash API, not a property of the store. | **Not cleanly** |
| Q2 | Reject bad events before persistence? | Yes — a validation on the event-log resource runs before persistence and aborts the whole wrapped action transaction (nothing persists). Caveat: AshEvents calls `create_event!/5` internally, so rejection **raises** out of the caller's action rather than returning `{:error, _}`. | Yes, with a raise-shaped API |
| Q3 | Global + per-stream ordering? | Global ordering: bigint PK sequence (`id`). **No per-stream sequence column** — `record_id` groups a stream but nothing provides `stream_seq`, so per-stream chains/optimistic concurrency have no native support. | **Not cleanly** |
| Q4 | Deterministic, independently testable replay? | Replay reproduces state and is stable across runs, but it works by **re-executing resource actions** (business logic + side-effect version routing), not by a pure fold over event data. Determinism is contingent on action purity, which the substrate's replay-audit property must not depend on. | Partial |
| Q5 | Metadata carries Envelope V1? | Metadata is `jsonb`: envelope fields round-trip as a string map, but **raw binaries are rejected** — signatures/hashes/pubkeys must be hex/base64-encoded, and canonical event bytes are not first-class (events are stored as decoded JSON, not the signed bytes). | **Not cleanly** |
| Q6 | Atomic multi-event append? | Only by wrapping calls in `Repo.transaction/1` yourself. No `expected_version`-style optimistic append control; appends serialize through a single global `pg_advisory_xact_lock`. | **Not cleanly** |

### 3.2 Decision

Per the hand-off rule — *"if any answer is 'not cleanly,' use Commanded + `eventstore` as the
canonical log instead"* — four of six answers are not clean. **The canonical log is
`eventstore` (Commanded's Postgres event store, v1.4.x, MIT)**, which natively provides: an
append-only schema (no UPDATE/DELETE grants on event rows), `$all` global ordering plus
per-stream versions (`stream_seq`), atomic batched appends with `expected_version` optimistic
concurrency, and `bytea` event data — so the **canonical signed bytes are stored verbatim** and
replay folds over exactly the bytes that were signed.

This does not split the log (hand-off §1: ONE canonical log): `eventstore` is *the* write log;
Ash enters in Phase 1B for domain/read-side modeling only, and AshEvents is not used. Full
Commanded (aggregates/command-handlers) is not adopted either — only the `eventstore` library,
wrapped by `CoopSubstrate.Log` (§4), which performs verify-on-append and dual-chain assignment.

## 4. The append-only log — `CoopSubstrate.Log`

### 4.1 Store layout

* Every event is appended — atomically, batches included — to the single physical stream
  **`ledger`**; its order IS the global chain. `global_seq` equals the ledger stream version,
  is assigned by the single serialized appender (a GenServer — hand-off §1: ONE canonical log),
  and is embedded in the hashed record.
* Each event is additionally **linked** (eventstore `link_to_stream`) into its derived
  per-stream stream for cheap selective reads. Links are a derived index, never canonical
  truth: per-stream integrity lives in the `stream_seq`/`prev_stream_hash` fields inside the
  hashed record, and missing links (a crash between append and link) are repaired from the
  ledger on restart.
* The store holds the `CoopEventCanonicalV1` bytes of the full record **verbatim** (`bytea`
  column, pass-through serializer): what is signed is what is stored is what is replayed.
  The store-level `event_id` is the ULID's 128 bits in UUID form, so re-appending the same
  event is a database-level conflict.

### 4.2 Verify-on-append

All checks run before anything persists; a batch is all-or-nothing (single
`append_to_stream` call with `expected_version`): structural validity (registered type,
payload schema with unknown-field rejection, `chapter_id`, signer-set shape), signature-set
completeness, every Ed25519 signature valid over the re-encoded core, canonical
encodability with size/depth caps, no prior log assignment, and no duplicate `event_id`.

### 4.3 Chain assignment & audit

Appends assign `stream_id` (derived, never author-supplied), `stream_seq`, `global_seq`,
`prev_stream_hash`, `prev_global_hash`; `event_hash` = SHA-256 over the canonical full
record (§2). Genesis links are `null`. `Log.verify_chains/0` audits from the raw stored
bytes: strict canonical decode (re-encode must reproduce the exact bytes), every signature
re-verified, both chains' prev-hash/sequence links checked for every event — and it collects
**every** failed check per record, so global-chain and stream-chain breaks are reported
independently (acceptance §6 item 4). Postgres-level append-only comes from eventstore's
`no_update_events`/`no_delete_events` triggers; the tamper tests bypass them as the database
superuser and prove both chains catch the forgery.

### 4.4 Reads & export

`read_all/1` (global order) and `read_stream/2` support `as_of:` a global sequence number
(06 P1 as-of evaluation). Reads strictly re-decode and re-validate; non-canonical bytes never
become terms. `export_stream/1` returns the raw canonical records of one stream;
`verify_export/1` independently verifies signatures and the per-stream chain with no access
to the store (08 §1 per-owner log export, minimal for 1A — full checkpoint publication is 1D).

*(§5 replay/projections and later sections are completed as their build steps land.)*
