# Phase 1A — Substrate Buildout: canonical signed event protocol + append-only log

> **Status: COMPLETE** (2026-07-05, through commit `2391595`). All build steps 0–9 done;
> every acceptance item below passes (`mix test` green incl. tamper property test,
> `cargo test` green, boot self-test gates startup, SUBSTRATE.md complete).
> Kept as the record of what 1A was scoped to be; Phase 1B is next.

New Elixir project at `~/coop_substrate`. Scope is strictly the hand-off's Phase 1A slice (items 1–11); acceptance = hand-off §6 items marked [1A]. Specs 00–13A + Amendment 01 received in-conversation; where they refine the hand-off, the spec governs (flagged inline below).

## Settled decisions (user-confirmed)
- **Project**: `coop_substrate` app (`mix new --sup`), git-initialized, at `/home/admin-papa/coop_substrate`.
- **Multi-signature**: Envelope carries an ordered, role-tagged **signature set**; all signers sign the same sig-excluded canonical bytes; append requires the event type's declared signer set complete. Witness attestations = separate events referencing the event hash.
- **Canonical encoder**: **Rust NIF** (Rustler) is the production encoder; a **pure-Elixir reference encoder** lives in `test/support` for cross-implementation byte-parity property tests (satisfies the "independent verifier" acceptance with implementation independence). Plain-NIF-safe per 08/§4 hand-off rule: bounded input (hard size cap, e.g. 64 KiB payload — placeholder constant), deterministic, no allocation surprises.
- **Event store**: AshEvents spike first (hand-off §1.7 + one added question: **atomic multi-event append**, needed by 06 P3 / batch semantics). Preliminary doc review suggests it fails cleanly (ordering by `occurred_at`, no documented append-only enforcement or pre-persistence rejection) → fallback **Commanded `eventstore` 1.4.8** per hand-off. Spike runs honestly; findings + decision recorded in `SUBSTRATE.md`. If *both* fail the envelope requirements, stop and flag for human decision (a custom append-only table is outside the hand-off's sanctioned pair).

## Flagged deviation from the hand-off sketch (spec-forced; document in SUBSTRATE.md)
The hand-off's envelope puts `prev_global_hash`/`global_seq` inside the signed bytes. That is incompatible with spec-mandated **bilateral/asynchronous dual signing** (05 §1.2, 07 §3, 08 §8): a counterparty cannot sign a global chain position that is only assigned at append. Resolution (certificate-transparency-shaped):
- **Signed core** (what every signer signs): `canonical_profile, schema_version, event_id (ULID), chapter_id, type, payload, signers[{role,pubkey,key_id}], auth_ref?, timestamp_ms` — stream identity is derivable from `type`+payload (08 §1, 07 P7), so signers bind to it implicitly; `auth_ref` = optional hash-pointer to the authorizing event (10 P1 provenance; required-per-type later).
- **Log-assigned at append**: `stream_id, stream_seq, global_seq, prev_stream_hash, prev_global_hash`.
- **event_hash** = SHA-256 over canonical encoding of the *full record* (core + signature set + chain fields) — so the dual chains are tamper-evident over signatures too. Chains: global (whole log) + per-stream.
- Author authenticity = sigs over core; history integrity = dual hash-chains; future checkpoints (1D) sign chain heads. Timestamps are author-asserted claims; **ordering authority is sequence, never wall-clock** (06 adversarial clock-skew, 10 "deadlines derive from log events").
- `chapter_id` required on every event; federation-scoped events (09 §1) flagged as an open representation question in SUBSTRATE.md — not resolved in 1A.

## Build steps (order matters; TDD throughout — tests written with/before each module)

### 0. Environment
- `mix local.hex --force && mix local.rebar --force`
- Install PostgreSQL via apt (server not present); create dev/test DBs.
- Install rustup + stable toolchain (not present); `cargo` available for NIF + verifier tests.
- `mix new coop_substrate --sup`; git init; deps: `rustler`, `cbor` (decode-side + reference), `stream_data` (test), store dep after spike.

### 1. `CoopEventCanonicalV1` written spec (SUBSTRATE.md first section)
Freeze, in writing, before any signing code: allowed payload types (int, UTF-8 string, binary, bool, nil, list, map w/ string keys); **floats forbidden** (money = integer minor units); map keys bytewise-lexicographic over encoded keys (RFC 8949 §4.2); shortest-form ints; **no CBOR tags**; `timestamp_ms` integer epoch-millis; UTF-8 exact-bytes (no normalization — reject invalid UTF-8); `schema_version` on every event; unknown fields rejected within a declared schema_version; evolution by new schema_version; profile change (V1→V2) requires explicit signed governance event; old events verify under original profile forever.

### 2. Rust NIF canonical encoder + committed test vectors
- `native/canonical_v1` Rustler crate: `encode(term) -> {:ok, bytes} | {:error, violation}` enforcing every §1 rule; input-size cap; also exposes SHA-256 of canonical bytes.
- Elixir reference encoder in `test/support/reference_encoder.ex` (same rules, independent code).
- `test/vectors/` — committed vectors: logical event → exact hex bytes → Ed25519 signature (keys committed for test vectors only). Rust-side `cargo test` verifies the same vectors independently of the BEAM.
- Property tests (StreamData): construction-order invariance (map insertion order shuffles ⇒ identical bytes); NIF ≡ reference encoder on generated terms; forbidden types rejected by both.

### 3. Ed25519 sign/verify + startup self-test
- `CoopSubstrate.Crypto`: sign/verify via OTP `:crypto` (eddsa/ed25519 — confirmed available on OTP 28.3.1).
- Application boot: assert `:eddsa` support, sign/verify RFC 8032 known vector + one committed envelope vector; **fail boot on mismatch**.

### 4. Event Envelope V1 + type registry (minimal)
- `Protocol.Envelope`: build/sign/verify per the signed-core design above; signature-set completeness check against the type's declared signer roles.
- `Protocol.TypeRegistry` (minimal for 1A): per-type → payload schema, required signer roles, stream-assignment function, disclosure class (commons/telemetry/edges — carried as data now, enforced later). Registry designed so a type's validity can later depend on prior log events (09 gated-N) without rework — a hook, not an implementation.
- 1A ships a handful of bootstrap types only: `TestProjectionEvent` (trivial), `CorrectionRecorded`, `KeyRotated`, `CharterConstantDeclared` (needed eventually by everything; trivially representable now).

### 5. AshEvents spike → store decision
- Throwaway project `spikes/ash_events_spike/` (ash ~3.x + ash_events 0.7 + ash_postgres). Answer §1.7's five questions + atomic multi-event append. Write spike report into SUBSTRATE.md; decide; delete or keep spike as documentation.
- Expected outcome: fall back to `eventstore` 1.4.8 (native append-only schema, `$all` global ordering, per-stream versions, metadata, atomic batched appends with `expected_version`). Decision recorded either way.

### 6. Append-only log (`CoopSubstrate.Log`)
- `append(envelope | [envelopes])` — single serialized appender (GenServer) per hand-off's one-canonical-log rule; batch append atomic.
- **Verify-on-append** (reject before persistence): canonical bytes valid, signature set complete + all sigs valid, chapter_id present, type registered, payload schema valid, size caps.
- Chain assignment: global chain + per-stream chain; `verify_chains/0..1` full and per-stream audit functions.
- Postgres-level append-only: rely on eventstore's schema (no UPDATE/DELETE grants) or equivalent; tamper test mutates a row via raw SQL as the DB superuser and asserts chain verification detects it (both chains).
- Ordered stream reads + as-of reads (foundation for 06 P1 as-of evaluation and future stream predicates; predicate hook stubbed, not populated).
- Signed per-owner/per-stream log export (08 §1) — minimal: export stream as canonical records; verification round-trips. (Full checkpoint publication is 1D.)

### 7. Deterministic replay + trivial projection
- `Log.replay(projection_module, opts)` — pure fold; trivial projection (e.g., per-chapter event counts + key registry from `KeyRotated`).
- Property: replay twice ⇒ identical state; replay is order-stable (global_seq order, never timestamps).

### 8. Corrections, key rotation, chapter enforcement (tests over the above)
- `CorrectionRecorded` references target event_hash; no code path mutates/deletes; test: original survives, chains verify, projection reflects correction as new event.
- `KeyRotated` recorded and reflected in key-registry projection (governance semantics deferred to 1D; representability is the 1A criterion).
- Schema-enforced `chapter_id` on every event (registry + envelope validation test).

### 9. SUBSTRATE.md
Document: CoopEventCanonicalV1 spec; Envelope V1 (incl. the flagged signed-core deviation + rationale); signing/verification rules; store decision + full spike report; chapter model note (built as *a* chapter; federation-scope open question); glossary mapping (system terms per 01; `EventEnvelope` vs `AuthorizationEnvelope` naming; E-n ↔ 04 entity names); 4a governance questions captured with current answers/deferrals; placeholder constants (size caps etc.) flagged as **PLACEHOLDER — awaiting charter declaration**.

## Explicitly deferred (not 1A)
Membership/capital/throughput/floor (1B/1C), privacy interfaces beyond disclosure-class *data* (1C), stream predicates population, checkpoints publication + key governance workflow (1D), demo seeding (post-1B), any Ash domain resources (1B — Ash enters with membership modeling unless the spike selects AshEvents as the log).

## Acceptance / verification (maps to hand-off §6 [1A] 1–9)
1. `mix test` green: vector tests, property tests (byte-stability, NIF≡reference), envelope sign/verify, verify-on-append rejections, chain tamper detection (global + stream), replay determinism, correction survival, chapter_id enforcement, KeyRotated representability.
2. `cargo test` in `native/canonical_v1` verifies committed vectors independently.
3. Boot self-test: `iex -S mix` boots; corrupting the known-answer vector makes boot fail (test via config override).
4. Tamper test: direct SQL UPDATE against a persisted event ⇒ blocked by grants/trigger; forced as superuser ⇒ `verify_chains` reports the break in both chains.
5. SUBSTRATE.md exists, complete per step 9.

**Gate:** nothing from 1B starts until all of the above pass — per hand-off §1A rule and 08 §9 phase gates.
