# SUBSTRATE.md — The Substrate: Canonical Signed Event Protocol, Append-Only Log, Membership, Capital Accounts

Status: **the substrate hand-off is complete** — Phases 1A, 1B (§11–§12), 1C (§13–§14), and
1D (§15–§16). This document is normative for the substrate. Where it deviates from the
hand-off sketch or the phase plans, the deviation is flagged and justified (see §2.1,
§11.2, §13, §15).

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

Phase 1B added the production identity/membership/capital types (§11), a
`{:payload_fields, prefix, [f1, f2]}` stream spec (per-(member, entity) streams), and realized
the `validity_check/2` hook: acceptance of a type can now depend on prior log events, checked
at the append gate (§11.3).

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

## 5. Replay & projections

A projection is a **pure fold** over the canonical log (`CoopSubstrate.Projection`:
`init/0` + `handle_event/2` — no side effects, no clock, no randomness). `Log.replay/2`
folds a projection over the ledger in `global_seq` order — never timestamp order; timestamps
are author-asserted claims with no ordering authority — and supports `as_of:` a global
sequence number. Replaying the same log twice reproduces the same state exactly, and the same
fold over an independently verified export produces the same state as replay against the
store (tested), which is what makes every derived number reproducible by any member from
events alone (invariant §0.5 of the hand-off).

This deliberately differs from AshEvents-style replay (which re-executes resource actions):
substrate determinism must not be contingent on business-action purity.

Phase 1A ships one trivial projection, `Projections.ChapterStats` (per-chapter counts, key
registry from `KeyRotated`, last event id per chapter). The 1B capital-account fold and 1C
throughput/floor computations are projections in exactly this shape, parameterized by
versioned rules.

## 6. The chapter model (1A scope)

Every event carries a required `chapter_id` (schema- and append-enforced), and every derived
stream id is chapter-prefixed (`<chapter_id>/...`), so all per-stream reads are chapter-scoped
by construction. One chapter exists today (tests use `chapter-genesis` as a stand-in name);
nothing anywhere assumes it is the only one — a second chapter is just a new `chapter_id`
value, no schema change (tested incidentally throughout the log suite with `chapter-two`).
Built as *a* chapter, not *the* center. Federation-scoped events (09 §1) remain an **open
representation question** — see §8.

## 7. Substrate governance (hand-off §4a) — current answers

Captured now so the data model never forecloses them; enforcement workflows are Phase 1D.

- **Who can rotate signing keys?** *(Answered in mechanism, 1D — §15.2–15.3.)* Member keys:
  self-rotation, signed by the member's current key, chained via `old_key_id`. Role keys
  (`governance`/`steward`/`checkpoint`): declared and revoked by governance-signed registry
  events, genesis by flagged trust-on-first-use. Governance-recovery rotation for a lost
  member key is open (§8).
- **Who can authorize a schema / canonical-profile migration?** Encoded in §1.3/§2: new
  fields require a new `schema_version`; a profile change (V1→V2) requires an explicit signed
  governance event; old events verify under their original profile forever. Readers reject
  foreign profiles/versions today (`from_full_record_term/1`), so a migration cannot happen
  silently.
- **Who can publish checkpoints, and where?** *(Built, 1D — §15.4.)* Anyone holding a
  declared `checkpoint`-role key emits `Log.checkpoint/3`; anyone with log access verifies
  independently (`Log.verify_checkpoint/1`: chain audit + head recomputation + as-of
  registry signature check). Where to publish is operational — any venue outside the
  primary database commits the operator to history.
- **Who holds decryption shares?** No encryption exists in the substrate yet, so no key to
  hold. The binding rule stands: no long-term architecture may depend on a single
  operator-held decryption key; day-one trusted encryption (when it arrives with the 1C
  privacy interfaces) lives behind those interfaces, labeled temporary.
- **What is exported to a member when they leave?** 1A-minimal: `export_stream/1` yields the
  raw canonical records of any stream, independently verifiable offline. 1B gives the member's
  data a concrete shape: their `members/`, `memberships/`, `patronage/`, and `redemptions/`
  streams (all keyed by `member_id`) plus the chapter's `accrual_rules` stream needed to
  reproduce their balance — the capital tests reproduce a balance from exactly such an export.
  The full export *workflow* remains 1D.
- **What is never put in the log?** Raw secrets, private keys, other members' private detail,
  or anything that cannot live forever — the log is append-only and eternal.
  Sensitive-but-removable data must be *referenced* from events (hash pointers, as with
  `auth_ref`/`target_event_hash`), never embedded.
- **Encrypted vs. redactable vs. tombstoned vs. corrected?** Corrections and reversals are
  new events referencing the target's `event_hash` (`CorrectionRecorded`); nothing mutates or
  deletes (DB-level triggers + chain audit enforce this). Redactable data is referenced, not
  embedded, so erasure outside the log cannot break the chains.

## 8. Open questions (flagged, not resolved)

- **Federation-scoped events** (09 §1): how an event that spans chapters is represented —
  a federation pseudo-chapter id, or a distinct scope field. Deferred to 1D; current model
  does not foreclose either.
- **Specs 00–13A** — *resolved*: the normative corpus is committed at
  [`docs/corpus/`](docs/corpus/) (00–13A + PROJECT_INSTRUCTIONS, with
  [`HANDOFF.md`](docs/corpus/HANDOFF.md) as its index, REVISION-2). The pre-refactor
  archive stays out of the repo — provenance only, per the corpus's own convention.
- **Registry governance**: production registration workflow for new event types (tests use
  the `:extra_event_types` app env; production types are compile-time data). The same applies
  to rule implementations (`:extra_accrual_rules`, `:extra_throughput_rules`,
  `:extra_floor_rules`).
- **Re-joining after a terminal membership state** (1B): the lifecycle allows no exit from
  `departed | retired | floor_exited | deceased` for the same (member, entity). Whether
  re-joining is a new membership record or a resurrection transition is a governance question.
- **Steward key registry** — *resolved in 1D* (§15.2): the role-key registry with
  bootstrap-then-enforce. What remains open is the role → **person** binding (`member_id`
  is informational) and per-role capability classes (10 §2) — governance semantics.
- **Genesis trust** (1D, §15.2): the first governance key per chapter is trust-on-first-use.
  Operational mitigation (publish the genesis checkpoint out-of-band) is doctrine, not
  mechanism.
- **Governance-recovery rotation** (1D → later): a member's lost key currently means a lost
  identity; social recovery / governance-signed rotation variants are open (08 §10.3).
- **Unsigned-proof policy** (1D, §15.5): whether verifiers demand signed proofs once a
  chapter has checkpoint keys is verifier policy — revisit when the first external verifier
  exists.
- **Stream-heads tree root** (1D, deferred): checkpoint covers the global head only;
  per-stream roots await a partial-verification or sync consumer.
- **Redemption enforcement** (1B → later): annual caps and payment-vs-balance checks are
  deferred workflow; the data structures carry the terms (§11.5) but the gate does not yet
  evaluate the capital fold.
- **Rail settlement's entity dimension** (1C, §13.2): member-level settlement currently
  counts toward every membership's floor — PLACEHOLDER awaiting the absent
  throughput_and_floor spec / charter.
- **Anti-gaming accretion** (1C → later): circular/self-dealing netting detection,
  per-counterparty caps (needs a privacy-preserving counterparty tag — an 08 §6 ladder
  decision), `NettingExecuted` batch discharge, exposure caps (05 P7) as gate checks.
- **Floor enforcement** (1C → 1D): evaluation cadence; requiring `evaluation_ref` on
  `MembershipFloorExited`; cure-window duration (undeclared charter constant).
- **n = 1 aggregates** (1C, §13.7): single-contributor totals equal the contribution; the
  k-anonymity gate is the declared upgrade when publication features arrive (08 §6).
- **Query authn** (1C → later): own-data classification is a contract, not yet middleware;
  the requesting-member context needs an API surface, which arrives with the first consumer
  (the stake view) — not with the substrate.

## 9. Placeholder (constitutionalized-later) parameters

All in `CoopSubstrate.Constants`, every one **PLACEHOLDER — awaiting charter declaration**
via future `CharterConstantDeclared` governance events:

| Constant | Placeholder value | Used by |
|---|---|---|
| `max_canonical_bytes` | 65 536 | encoder input cap (NIF safety rule, hand-off §4) |
| `max_canonical_depth` | 32 | encoder nesting cap |
| `default_accrual_weight_bp` | 10 000 | `capital-accrual-v1` fallback weight (§11.4) |
| `throughput_components` | delivery/match/custody/labor_hour | recordable claim set (§13.2; settlement derives from the rail) |

Phase 1B economic parameters are **versioned in-log, never hardcoded**: the accrual rule and
its weights arrive per chapter via `AccrualRuleActivated{rule_id, params}` (the whole
`capital-accrual-v1` linear rule is itself a PLACEHOLDER), and redemption terms (`years`,
`annual_cap_minor`, `method`) travel inside each `RedemptionScheduleOpened` event. Entity
classes (`Constants.entity_classes/0`: carriers/workers/mechanics co-ops) come from
master_design §3 via the hand-off — extending them is a governance act. Signer-role
assignments on 1B/1C types are PLACEHOLDER governance semantics (§11.3). Phase 1C tightened
the discipline: throughput weights and floor thresholds/windows arrive **only** via gated
`ThroughputRuleActivated`/`FloorRuleActivated` params with required fields and no code
fallback (§13.2, §13.4).

## 10. Phase 1A acceptance status

Hand-off §6 [1A] items, all enforced by the test suite (`mix test`; Rust-side
`cargo test` in `native/canonical_v1` independently verifies the committed vectors):

1. ✅ Canonical profile frozen; committed vectors pass in both implementations; byte-stability
   property tests (construction-order invariance; NIF ≡ reference encoder).
2. ✅ Ed25519 startup self-test (RFC 8032 vector + committed envelope vector); corrupting a
   known answer fails boot (tested via config override).
3. ✅ Envelope V1; signatures cover the sig-excluded canonical core; verification re-encodes.
4. ✅ Append-only & tamper-evident: raw SQL UPDATE/DELETE blocked by store triggers;
   superuser forgery detected by BOTH chains (example + property tests).
5. ✅ Invalid/missing signatures rejected before persistence (batch is all-or-nothing).
6. ✅ Deterministic replay of `ChapterStats`; order-stable by `global_seq` against
   adversarially reversed timestamps; independently reproducible from an export.
7. ✅ Corrections are new events; the original survives byte-identical and chain-valid.
8. ✅ `chapter_id` required on every event (envelope layer and append gate).
9. ✅ `KeyRotated` representable, recorded, and folded into the key-registry projection.

**Gate:** Phase 1B (membership + capital accounts) may start. *(Passed; see §11–§12.)*

---

## 11. Phase 1B — identity, membership lifecycle, capital accounts

Scope: hand-off §2.2–2.3; plan and flagged decisions in `docs/phase1b_plan.md`.

### 11.1 Identity, entities, membership records

A member (person) is a `member_id` bound to an Ed25519 key by `MemberRegistered` —
**self-certifying**: the declared `member`-role signer must be exactly the registered
(pubkey, key_id), enforced at the gate. `KeyRotated` (1A) moves the *current* key; the gate
follows rotation, so a membership event signed with a stale key is rejected even though the
signature is cryptographically valid. Entities are declared by `EntityRegistered` with
`class ∈ Constants.entity_classes/0`. A membership is **(member, entity, class)** — dual
membership is two records with two independent capital accounts, never merged. Everything is
chapter-scoped: gate and projections key by `chapter_id`; the same ids in another chapter are
a different world (tested).

### 11.2 The lifecycle machine — FLAGGED DEVIATION: pure fold, not AshStateMachine

`CoopSubstrate.Membership.Lifecycle` is an exhaustive, explicit transition table (pure data +
total `apply/2`); the full states × events matrix is property-checked:

| Event | From | To |
|---|---|---|
| `MembershipInvited` | *(none)* | `invited` |
| `MembershipProbationStarted` | `invited` | `probationary` |
| `MembershipConfirmed` | `probationary` | `member` |
| `MembershipDeparted` | `invited`, `probationary`, `member` | `departed` |
| `MembershipRetired` | `member` | `retired` |
| `MembershipFloorExited` | `member` | `floor_exited` |
| `MembershipDeceased` | `probationary`, `member` | `deceased` |

Terminal states are the redeemable-account states; nothing leaves them (re-joining: open
question, §8). Flagged extrapolations beyond the hand-off's arrows: invited→departed,
probationary→departed, probationary→deceased. Cure/hardship arrives with the 1C floor.

The hand-off sketch names AshStateMachine; it is **not** adopted, for the same reason
AshEvents was not (§3, §5): substrate state must be a pure fold over canonical bytes, and the
*enforcement point* must be the append gate — otherwise illegal transitions could enter the
eternal log and every replayer would need business logic to skip them. An Ash read-side
resource can materialize from the projection when the first consumer (the stake view, a later
cold-start step) exists; nothing here forecloses that.

### 11.3 The append gate (validity realized)

The 1A `validity_check/2` hook is now real: `CoopSubstrate.Protocol.Validity` checks each
envelope against the **gate state** — a `Projections.Membership` fold (entities, members with
current keys, membership states, active accrual rule per chapter, open schedules) held by the
single serialized appender beside the chain head, rebuilt from the ledger on recovery, and
threaded through each batch in order (event N sees N−1; a violation rejects the whole batch
before anything persists). The gate state is a pure function of the log prefix, so every
accept/reject decision is deterministic and reproducible from events alone.

Checks: registration existence/uniqueness; transition legality per §11.2; invited class must
match the entity's; member-role signatures must use the member's current key; accrual-rule
activations must name a known rule with valid params; patronage requires an active membership
(PLACEHOLDER: probationary accrues), an active rule, and a positive amount; schedules open
once, only on redeemable accounts, with sane terms; payments require an open schedule.
`KeyRotated` stays ungated (rotation governance is 1D). Signer-role assignments (steward vs
member vs dual-signed `MembershipConfirmed`) are PLACEHOLDER governance semantics — *who may
author* is the 1D validity workflow.

### 11.4 Capital accounts — the accrual engine

`Projections.CapitalAccounts` is a pure fold in the 1A projection shape, queried via
`CoopSubstrate.Capital` (`account/4`, `balance/4`, `sinking_fund/3`, all supporting `as_of:`):
`account(member, asOf) = fold(rule_vN, events(member, ≤ asOf))`. Value is ledger arithmetic in
integer minor units, never appraisal.

**Rule versioning is in-log.** `AccrualRuleActivated{rule_id, params}` switches the active
rule per chapter *forward*; implementations are pure modules behind
`Capital.AccrualRules` (registry) / `Capital.AccrualRule` (behaviour). Every accrual entry
records the `rule_id` and the credited amount computed at fold position, so activating a new
rule can never mutate a historical entry — tested by as-of replay across a rule change.
`capital-accrual-v1` (`Rules.LinearV1`, weighted-linear over `weights_bp`) is a PLACEHOLDER
formula end to end.

Accounts move `:accruing → :redeemable` on any terminal exit (`:estate` with `estate_ref` for
death-to-estate) and `→ :in_redemption` when a schedule opens. Reproducibility is tested two
ways: an independent naive fold over `read_all`, and the same fold over independently
*verified* stream exports merged by `global_seq` — both must equal the projection's answer.

### 11.5 Redemption structures (data now, workflow later)

`RedemptionScheduleOpened` carries the constitutionalizable terms (`years`,
`annual_cap_minor`, `method: "fifo"`); `RedemptionPaid` consumes accrual entries **FIFO** and
draws the entity's sinking fund (`SinkingFundContributed` accumulates it). No payout engine,
cap enforcement, or eligibility logic exists yet (§8) — the data structures support
multi-year payout, sinking-fund accounting, annual cap, FIFO, and death-to-estate, which is
the 1B requirement.

## 12. Phase 1B acceptance status

Hand-off §6 [1B] items, enforced by the test suite:

10. ✅ **Membership lifecycle**: exhaustive matrix property test (every undeclared
    (state, event) pair rejected); every transition a signed event on the real log; illegal
    transitions rejected *before persistence* with chains verifying after; dual membership
    across entities with independent records; departed/retired/floor-exited/deceased all
    reach redeemable-account states (deceased → estate); gate survives appender restarts;
    member-key authenticity follows `KeyRotated`; batches atomic with intra-batch visibility;
    chapters isolated.
11. ✅ **Capital-account fold**: pure fold of (events, in-log rule version); rule change
    applies forward only (as-of replay across the change is byte-stable); entries record
    their `rule_id`; redemption structures present (schedule terms, FIFO consumption,
    sinking fund, estate routing); any member's balance reproduced independently from
    `read_all` AND from verified stream exports; replay deterministic.

**Gate:** Phase 1C (throughput/floor + privacy seams) may start. *(Passed; see §13–§14.)*

---

## 13. Phase 1C — throughput, floor, obligation rail, privacy seams

Scope: hand-off §2.4–2.5 + §4; plan and flagged decisions in `docs/phase1c_plan.md`. This is
the first phase grounded in the **normative corpus** (`docs/corpus/` — see §8):
08_PLATFORM (privacy mechanism ladder §6, verification doctrine §9),
05_FINANCE (obligation-relationship rail §1.2; P5/P10/P11), 11_HARNESS (spec-shape rule; the
harness gates workflow builds, not the substrate — the substrate is HANDOFF §5's phase gate).

### 13.0 Spine

```
throughput(member, entity, window, as_of) = fold(rule_vN, component events ≤ as_of in window)
cleared?(member, at)                      = throughput(m, [at − window_ms, at)) ≥ threshold_vN(class)
aggregate(chapter, metric)                = Privacy.Aggregate.sum(contributions)   — seam, not sum
settlement evidence                       = discharge events on the obligation rail — never funds
```

Everything is a pure function of (log, in-log rule version); no code path reads a clock —
evaluation instants and windows are caller-supplied, so every verdict is `as_of`-reproducible.

### 13.1 Floor lifecycle states

`Membership.Lifecycle` gains `in_cure` and `hardship` (hand-off §2.4 "cure/hardship state in
the membership machine"): `member ⇄ in_cure` (`FloorCureStarted`/`FloorCureCleared`),
`member ⇄ hardship` (`HardshipDeclared`/`HardshipEnded`, member-signed), `in_cure →
floor_exited`, and departure/death reachable from both. Hardship **suspends floor
evaluation** (`floor_suspended?/1`) — enforced symmetrically at the gate
(`FloorEvaluationRecorded` rejected) and in the query (`Floor.cleared?` returns the same
error). `in_cure`/`hardship` remain active-for-accrual — PLACEHOLDER governance semantics,
like probationary in 1B.

### 13.2 Throughput — the compute layer

`ThroughputRecorded{member_id, entity_id, component, units, occurred_ms, source_ref?}` is the
**G0-claim carrier** (corpus 08 §4): `component ∈ Constants.throughput_components()`
(PLACEHOLDER set; the hand-off's cited throughput_and_floor spec remains absent).
`settlement` is deliberately not recordable — it derives from obligation-rail discharges.
Counterparty identity is deliberately **not a field** (corpus 07 §5: edges are sovereign);
per-counterparty caps await an 08 §6 ladder decision (§8).

`Projections.Throughput` mirrors the capital fold: entries weighted by the chapter's active
rule *at fold position* (`ThroughputRuleActivated`, gate-validated against
`Throughput.Rules`; `Rules.WeightedSumV1` requires `default_weight_bp` in the activation —
**no code fallback**, 00 Art. IV.2), every entry records its `rule_id`, activations apply
forward only (as-of byte-stable, tested). Queries: `Throughput.value/5` over the half-open
event-time window `[from_ms, to_ms)`; `entries/4` (own-data).

**FLAGGED — entity dimension of rail settlement.** Obligations are member-to-member;
throughput is per (member, entity). Discharges credit **both parties** in a member-level
bucket (`entity = nil`), and the windowed query counts a member's rail settlement toward each
of their memberships. After assignment the credit binds to the *current* debtor. A discharge
before any throughput rule is active credits nothing (no weight to run) — deterministic
either way. All PLACEHOLDER semantics awaiting the absent spec/charter.

### 13.3 The obligation rail (corpus 05 §1.2)

`ObligationRecorded{obligation_id, debtor_id, creditor_id, amount_minor, denomination}` /
`ObligationAssigned{obligation_id, new_debtor_id}` / `ObligationDischarged{obligation_id}` —
all dual-signed, `:bilateral`-classed, riding the obligation's own stream. Gate: parties
registered, distinct, signing with their **current** keys (rotation-following, as 1B);
obligation ids unique per chapter; assignment/discharge only while open; discharge-once;
assignment onto the creditor rejected (it reconstructs a discharge without dual attestation —
stratagem resistance, 08 §2). **No event type represents fund movement** (05 P11): settlement
is external, attested by the dual-signed discharge. [LEGAL] the money-transmission boundary
is a counsel gate before external use (corpus HANDOFF §4).

**Netting** (05 P5, P10): `Finance.netting/3` — per-denomination pairwise set-off over open
mutual obligations, `setoff = min(gross each way)`, residual net stated as (debtor, creditor,
amount). A pure report; executing a round (batch discharge) is deferred (§8). The obligations
state lives in the same fold the append gate holds — one fold, two consumers; the plan's
separate `Projections.Obligations` proved unnecessary.

### 13.4 The participation floor

`Floor.cleared?(chapter, member, entity, at:, as_of:)` — windowed throughput (including rail
settlement) against the active `floor-threshold-v1` params (`window_ms`,
`default_threshold_minor`, per-class `thresholds_minor` — all REQUIRED in the activation, no
code fallback). No-membership, no-active-rule, and hardship are distinct non-verdict states,
not `false`. `FloorEvaluationRecorded` is representable (gate binds `rule_id` to the active
rule) so floor exits have something to reference — but the gate does **not** yet require an
`evaluation_ref` on `MembershipFloorExited`, and nothing automates evaluation cadence:
deferred workflow, 1D-shaped (§8), same posture as 1B redemption enforcement.

### 13.5 Privacy seams (hand-off §4, sized by corpus 08 §6)

- **`Privacy.Aggregate`** — `sum/1`; backing from `:aggregate_backing` app env, default
  `Plaintext`. Every cross-member summation routes through it: `Throughput.system_value/3`,
  `Capital.sinking_fund_total/2`. The seam-swap test runs the identical assertion function
  under both backings — zero caller changes (acceptance 13).
- **`Privacy.Proof`** — `prove/2`, `verify/2`; default backing `TrustedAudit`: a proof is the
  fact plus the pinned log position, and `verify` IS the audit (full recomputation — an old
  proof still verifies after rules tighten, because it pinned its position). First facts:
  `floor_cleared`, `balance_at_least`. **FLAGGED DEVIATION**: the assertion is unsigned —
  no operator/role key exists until 1D key governance; the pinned position carries
  auditability, the signature attaches when the key does.
- **`Privacy.JointCompute`** — behaviour only (the hand-off's explicit instruction); the
  first backing arrives with the first network feature.

Per 08 §6/§9 no HE/ZK/enclave code exists; escalation requires a demonstrated failure of the
plain rung.

### 13.6 No-surveillance classification (hand-off invariant §0.6)

The whole public query surface (`Capital`, `Throughput`, `Floor`, `Finance`,
`Privacy.Aggregate`, `Privacy.Proof`) is enumerated in one test and classed
`own_data | bilateral | aggregate | system`; an unclassified export **fails the suite**, so
the review happens at the moment of addition. `:bilateral` is a fourth class beyond the
plan's three (netting exposes only the pair's co-signed positions — corpus 07 §5).
**FLAGGED DEVIATION**: no `for_member:` request context yet — with no authn layer it would be
an unchecked parameter; queries are subject-keyed and the classification map is the contract
the 1D enforcement middleware implements.

### 13.7 Properties & adversarial results

Plan P1–P9 all enforced by the suite (purity/forward-only P1–P3: `throughput_test`,
`floor_test`; lifecycle exhaustiveness P4: matrix property; rail P5–P6: `obligation_rail_test`
+ the registry's fund-movement-absence check; netting P7: set-off property; seam P8:
swap test; classification P9: enumeration test). Adversarial suite outcomes: self-crediting
on a departed membership → gate-rejected · discharge replay / double discharge → rejected ·
assignment after discharge → rejected · cross-denomination netting → structurally impossible
(property-checked) · rule params smuggling a constant bypass → activations validate, required
params have no fallback · floor evaluation under a stale rule → gate rejects non-active
`rule_id` · own-data query for another member → classification contract (enforcement 1D) ·
**n = 1 aggregate leakage → documented, not blocked**: a single-contributor total is that
contributor's value; the k-anonymity gate is the declared upgrade (08 §6) when publication
features arrive (§8).

## 14. Phase 1C acceptance status

Hand-off §6 [1C] items, enforced by the test suite:

12. ✅ **Pure, versioned compute**: throughput and floor are pure functions of (events,
    in-log rule version); parameters placeholder-marked and delivered via gated activation
    events (stricter than "externally configurable" — declared before first evaluation);
    rule changes forward-only, as-of byte-stable; v0 is the minimal fold, anti-gaming
    graph logic deferred as planned.
13. ✅ **Privacy seam swap**: aggregate callers depend on `Privacy.Aggregate` only; the
    swap test runs identical assertions under plaintext and a marked stub backing with
    zero caller changes.
14. ✅ **No-surveillance**: the query surface is enumerated and classified; unclassified
    exports fail; aggregate paths return bare totals; bilateral reports are shape-closed;
    absence tested, not asserted.

`cargo test` unchanged and green (1C added types, not encoding). 1A/1B suites untouched.

**Gate:** Phase 1D (chapter scoping beyond the id, external checkpoints, governance/key
structure) may start. *(Passed; see §15–§16.)*

---

## 15. Phase 1D — chapter scoping (full), checkpoints, governance/key structure

Scope: hand-off §3 + §4a; plan and flagged decisions in `docs/phase1d_plan.md`. Grounding:
corpus 08 §1/§9 (key custody discipline: no premature threshold crypto), 04 §7 (stateless
roles, key-ceremony succession), 00 Art. IV/VI.

### 15.1 Chapters stay implicit; the federation is a computation

A chapter is its id — no chartering event gates it (04: chapters are sovereign). A second
chapter joins with **zero** schema/registry/code change (tested by seeding two chapters
through the unmodified 1B/1C types). Federation reach is aggregate-only:
`Throughput.federation_value/3` sums sovereign chapter folds through the `Privacy.Aggregate`
seam — a computation, never an event; only totals cross chapter lines. The *representation*
of federation-scoped events (09 §1) stays open (§8).

### 15.2 The role-key registry (the "who can author" answer)

`RoleKeyDeclared{role, key_id, pubkey, member_id?}` / `RoleKeyRevoked{role, key_id}` on the
chapter's `governance` stream; `role ∈ Constants.declarable_roles()` (`governance`,
`steward`, `checkpoint` — `member` keys live in the member registry, never here). The
registry is a fold in the gate state; a role holds **N concurrent keys** (threshold custody
not foreclosed; none built — 08 §9).

- **Genesis**: a chapter's first `governance` declaration is trust-on-first-use,
  self-certified (the `MemberRegistered` pattern). **FLAGGED**: TOFU is the bootstrap trust
  assumption; publishing the genesis checkpoint out-of-band is its mitigation. Before
  genesis, nothing else in the registry is representable.
- **Everything after is governance-signed**: a generic gate check (`check_role_keys/2`,
  in front of every per-type check) requires every signature in a *declared* role to match
  a currently declared key.
- **Bootstrap-then-enforce, irreversibly**: a role never declared is unchecked (the pre-1D
  behavior, now named — the 1A–1C suites run in bootstrap unmodified); the first declaration
  closes the door; an emptied role stays closed until governance declares a new key.
- **No orphaning**: revoking the last governance key is unrepresentable.
- **FLAGGED PLACEHOLDER**: `member_id` binds role → person informationally only; *which
  member* may act under a role key (10 §2 capability classes) remains governance semantics.

### 15.3 `KeyRotated` gated — self-rotation

For a registered member: signed by the member's **current** key, with `old_key_id` matching
it — rotations chain; hijack and stale-rotation replay are unrepresentable. Unregistered ids
stay inert-and-ungated (1A compatibility). Governance-recovery rotation (lost key, social
recovery — 08 §10.3) is open (§8). This closes the last 1A "ungated" flag: member keys are
governed by self-rotation, role keys by the registry.

### 15.4 External checkpoints

`Log.checkpoint(chapter, key_id, seed)` emits a self-contained blob: the canonical encoding
(`CoopEventCanonicalV1`, unchanged) of
`{schema: "CheckpointV1", chapter_id, key_id, global_seq, global_hash}` plus an Ed25519
signature over those bytes. `Log.verify_checkpoint/1` independently audits both hash chains
up to the claimed position, recomputes the head from raw stored bytes, and validates the
signature against the chapter's `checkpoint` keys **as of that position** — later revocation
never invalidates a historical attestation; a revoked key cannot attest any newer head.
Publishing the blob outside the primary database (git, another host, a member's phone)
commits the operator to the entire history — the 00 Art. VI detection mechanism. Emission
does not consult the registry; verification decides trust. The stream-heads tree root is
deferred (§8).

### 15.5 Signed proofs (closes the §13.5 deviation)

`TrustedAudit.prove(fact, sign_with: {key_id, seed})` signs the assertion with a
`checkpoint`-role key; `verify` validates against the as-of registry AND still recomputes —
signature adds authority, never replaces the audit. Unsigned proofs keep verifying by
recomputation alone (bootstrap unchanged); whether a verifier demands signatures
post-bootstrap is verifier policy, deliberately not encoded.

### 15.6 Adversarial results

Genesis race → TOFU by construction (flagged; out-of-band genesis checkpoint is the
mitigation) · rogue steward/governance key after close → rejected · revoked/rotated-out
governance key → rejected · orphan-governance revocation → unrepresentable · rotation hijack
/ stale old_key_id → rejected · checkpoint by undeclared key / forged signature / forged
head position → verification fails · ledger tampered under a checkpoint → chain audit fails
it · proof signed by undeclared or post-revocation key → verify false; tampered signature
false despite a true fact.

## 16. Phase 1D acceptance status

Hand-off §6 [1D] items, enforced by the test suite:

15. ✅ **Chapter scoping (full)**: queries chapter-scoped throughout; a second chapter
    joins with no schema change (tested); federation aggregate spans chapters via the
    `Aggregate` seam.
16. ✅ **Checkpoints externalizable**: signed global head emitted as a self-contained
    canonical blob; independently verified (chain audit + head recomputation + as-of
    registry signature check); tamper, rogue-signer, and forged-head cases fail.
17. ✅ **Key governance not foreclosed**: roles hold N concurrent keys (threshold/
    multi-party structure permitted, none built); zero decryption keys exist anywhere;
    canonical-profile migration path and member-export semantics specified (§7).

`cargo test` unchanged and green (checkpoints reuse the frozen profile). 1A–1C suites
green — the pre-1D suites run in bootstrap mode by construction.

**Gate:** the substrate hand-off (phases 1A–1D) is **complete**. Anything further —
enforcement workflows, consumer surfaces, the stake view — is a new brief that reads from
this substrate.
