# Hand-off: Substrate Buildout (Coding Agent)

**Scope of this hand-off:** build the **substrate only** — the signed event ledger + capital-
account accrual + the privacy-capable foundation that every other feature reads from. This is
step 1 of `coldstart.md` ("Ledger + capital-account substrate, invisible, day one"). It is NOT
the dispatch tool, the stake view, governance workflow, or network features — those are later
steps that *read from* this substrate. Build this correctly and everything else accretes onto it.

**Read before coding (in this repo):** `README.md`, `master_design.md` §1–2 + §7, `governance.md`
§6/§8/§10, `privacy_architecture.md` (all), `throughput_and_floor.md` §7. Do not re-derive the
design; implement against it. Where this hand-off and a spec conflict, the spec governs — flag it.

**Build in phases — do NOT build the whole substrate in one pass.** The substrate is large
(canonical encoding, signing, append-only log, membership, capital accounts, throughput/floor,
privacy seams, chapters, checkpoints, key governance). Building capital accounts or floor logic
before the event substrate is *trustworthy* is the main failure mode. Build strictly in order:

- **Phase 1A — canonical signed event protocol + append-only replayable log** (the slice below).
  *Nothing else starts until 1A passes its acceptance tests.*
- **Phase 1B — membership lifecycle + capital-account fold** (§2.2–2.3).
- **Phase 1C — throughput/floor compute + privacy interfaces** (§2.4–2.5, §4) — start with minimal
  pure folds and interface stubs; the full anti-gaming logic accretes later.
- **Phase 1D — chapter scoping (beyond the id), external checkpoints, governance/key structure**
  (§3, §4a) — the parts beyond what 1A already requires.

---

## Phase 1A — Minimal build slice (build ONLY this first)

Before any membership, capital, throughput, floor, or privacy-backend work, implement only:

1. **`CoopEventCanonicalV1`** written spec (§1.5).
2. **Canonical encoder** with committed byte-level test vectors (§1.5).
3. **Ed25519 sign/verify startup self-test** (§1.5).
4. **Event Envelope V1** — the precise signed envelope (§1.6).
5. **Append-only canonical log** using the chosen event store (§2.1) — *after the AshEvents spike
   (§1.7) confirms it can carry the envelope and enforce append-only; else fall back to
   Commanded+eventstore.*
6. **Dual hash-chain verification** — global chain + per-stream chain (§1.6).
7. **Deterministic replay** of one trivial projection.
8. **Correction-as-event** (no mutation, no delete).
9. **Chapter id required on every event.**
10. **Basic key-rotation event** representable and recorded in the log.
11. **`SUBSTRATE.md`** documenting all the above.

**Rule: no domain logic may depend on unsigned or non-canonical events.** 1A is "done" when its
acceptance subset (§6, items marked **[1A]**) passes. Only then start 1B.

---

## 0. Non-negotiable invariants (these are correctness, not preferences)

The substrate must make these structurally true. Treat violations as build-breaking:

1. **Immutable record, amendable rules.** The event log is append-only and tamper-evident; the
   *rules/formulas* that compute over it are versioned and amendable by the (future) consent
   process. Never make rules immutable; never make the record mutable.
2. **Every consequential fact is a signed event.** Membership changes, capital-account accruals,
   votes, throughput components, custody, settlement — all signed, attributable, append-only.
3. **Objective, ledger-computed, non-discretionary.** Capital accounts, throughput, and the
   participation floor are *computed from events by deterministic, pure functions* — never set by
   judgment. (Governance §0, the whole design's spine.)
4. **Privacy boundaries are real from day one** (even if the heavy crypto is staged):
   - A member's private data stays in their boundary; only proofs/protected-aggregates cross out.
   - The substrate must never *require* exposing a member's raw freight/rates/customers to the
     network or to other members to function.
   - Cryptographic operations sit **behind interfaces** so implementations can be swapped
     (trusted-but-auditable → ZK/HE/MPC) without re-architecting. See §4.
5. **Auditable/legible.** Any member can reproduce any number that affects them from the events.
   Determinism + event-sourcing must make this a property, not an afterthought.
6. **No surveillance.** The substrate exposes *system aggregates and a member's own data*, never
   one member's detail to another.

If a requested feature would violate one of these, stop and flag — do not "make it work" by
breaking an invariant.

---

## 1. Stack & conventions

- **Language/runtime:** Elixir on the BEAM. **Ash** for resources/domain modeling. Postgres for
  the materialized read side; the append-only event store is the source of truth.
- **ONE canonical event log — pick exactly one, do not split.** AshEvents and Commanded+eventstore
  solve overlapping problems; running both creates two competing "append-only truths" with no
  single auditable source. Choose:
  - **AshEvents** (centralized Ash-native event log with replay; ~v0.7.x on Ash core ~3.29.x) —
    *default*, since the domain is modeled in Ash. Event capture/replay around resource actions.
  - **Commanded + `eventstore`** (Postgres-backed, MIT, v1.4.x; atomic appends + optimistic
    concurrency via `expected_version`) — only if you want explicit CQRS event-sourced aggregates
    and command handlers.
  **Recommendation: AshEvents as the canonical log.** Whichever is chosen is *the* write log; the
  other is not used for canonical truth. Record and justify the choice in `SUBSTRATE.md`.
- **Style:** immutable, declarative, DRY; pure functions for all computation over events
  (capital accrual, throughput, floor). **TDD — tests first**, property-based tests where the
  invariants are universal (append-only, determinism, reproducibility).
- **Signing:** Ed25519 over the **canonical encoding profile defined in §1.5** (not "CBOR
  generically"). Prefer OTP `:crypto`/`:public_key` for Ed25519 (native, no NIF) with a startup
  self-test (see §1.5); `enacl` only if libsodium byte-parity with a Rust/sidecar verifier is
  required. **Signing is meaningless until the canonical profile is locked** — different encoders
  must produce byte-identical output for the same logical event, or signatures and hash-chains
  don't verify across implementations.
- **Formal-ish rigor where it pays:** the accrual/throughput/floor functions are pure and
  total; test them as such. State machines (membership lifecycle) via AshStateMachine with
  explicit, exhaustive transitions.

---

## 1.5 PROTOCOL REQUIREMENT #1 — `CoopEventCanonicalV1` (do this before anything signs)

Deterministic encoding is **not a library option; it is a protocol you own and freeze.** The
Elixir `cbor` package implements RFC 8949 but does **not** guarantee canonical/deterministic
output (it does not bytewise-sort map keys or enforce shortest-form), so "sign the encoded map"
is *performative* until you define and test the exact byte profile. Without this the entire
Ed25519/hash-chain layer is theater — two implementations can sign different bytes for the same
logical event.

**Deliverable: a written spec `CoopEventCanonicalV1`** (in `SUBSTRATE.md`) fixing, explicitly:
- **Allowed types** (and forbidden ones) for event payloads.
- **Map-key ordering** — bytewise lexicographic over deterministic key encodings (RFC 8949 §4.2).
- **Integer policy** — preferred shortest-form; no non-minimal encodings.
- **Float policy** — forbid floats in canonical events (money is integer minor units; decimals as
  scaled ints or strings), or fix an exact float rule.
- **Tag policy** — which CBOR tags are allowed; reject others.
- **Timestamp format** — one fixed representation (e.g. integer epoch-millis), never ad hoc.
- **Binary/string normalization** — fixed UTF-8 form, no ambiguous encodings.
- **Schema-version location** — every event carries `schema_version`; the canonical-profile
  version is recorded.
- **Unknown-field policy & migration** — unknown fields are rejected *within a declared
  `schema_version`* (clean canonical bytes). Protocol evolution is handled by versioning, not by
  loosening: **new fields require a new `schema_version`; a canonical-profile change
  (`CoopEventCanonicalV1` → `V2`) requires an explicit signed governance event; old events remain
  verified under their original profile/version forever.** This is "immutable record, amendable
  rules" applied to encoding.

**Implementation choice:** either (a) normalize/sort deterministically in Elixir before
`CBOR.encode/1` and enforce the rules, or (b) implement the canonical encoder as a small **Rust
NIF** (byte-parity with any Rust/sidecar verifier). Given the crypto boundary already wants Rust,
(b) is attractive — but either way it must be **locked with published test vectors.**

**Acceptance (blocking): byte-stability + cross-impl vectors.** Property tests assert
logically-equal events encode to identical bytes regardless of construction order; a committed set
of **canonical test vectors** (event → exact bytes → signature) must match an independent (Rust)
verifier. **Ed25519 startup self-test:** assert `:crypto.supports()` includes `:eddsa`, sign/verify
a known vector, confirm it matches the cross-language verifier — fail boot if not.

Nothing else in §2 may sign or hash-chain until `CoopEventCanonicalV1` is frozen and its vectors
pass.

---

## 1.6 The event envelope & the two hash-chains (precise, not a sketch)

The earlier loose tuple `{type, payload, author_pubkey, prev_hash, sig, ts}` is **insufficient for
canonical signing.** Define a precise **Event Envelope V1**, and be explicit about *what is signed*:

```
%{
  canonical_profile: "CoopEventCanonicalV1",
  schema_version:    "EventEnvelopeV1",
  event_id:          <uuid/ulid>,
  chapter_id:        <chapter>,          # required on every event (§3)
  stream_id:         <entity/member/account stream>,
  stream_seq:        <int>,              # per-stream monotonic
  global_seq:        <int>,              # total-log monotonic
  type:              <event type>,
  payload:           <canonical-typed map>,
  author_pubkey:     <ed25519 pub>,
  key_id:            <which key; supports rotation>,
  prev_global_hash:  <hash>,             # global chain
  prev_stream_hash:  <hash>,             # per-stream chain
  timestamp_ms:      <int epoch millis>
  # sig is stored BESIDE the envelope, NOT inside the signed bytes
}
```

**Signing rule:** sign the canonical encoding of the envelope **without** `sig` (you cannot sign
bytes that contain the signature). Store `sig` alongside. Verification re-encodes the
sig-excluded envelope canonically and checks the signature.

**Two chains, both required** (the loose single `prev_hash` is not enough):
- **`prev_global_hash`** — chains the entire log; proves total-history integrity.
- **`prev_stream_hash`** — chains each stream (member/account/entity); makes per-member/per-account
  audit and selective verification cheap without replaying the whole log.
Checkpoints (§4a) sign the current global head (and optionally a tree root over stream heads).

---

## 1.7 AshEvents spike report (do before committing to it as the canonical log)

AshEvents is the *default* choice (Ash-native) but is newer than Commanded/eventstore. Before
building 1A on it, produce a short **spike report** answering:
- Can it enforce **append-only** (no update/delete of past events)?
- Can it **reject bad signatures / non-canonical events before persistence** (or is there a clean
  hook to)?
- Does it support **global ordering and per-stream ordering** (for `global_seq`/`stream_seq`)?
- Is **replay deterministic and independently testable**?
- Can event metadata cleanly carry the full **Envelope V1** (`prev_global_hash`,
  `prev_stream_hash`, `sig`, `author_pubkey`, `key_id`, `schema_version`, `chapter_id`)?

**If any answer is "not cleanly," use Commanded + `eventstore` as the canonical log instead.** The
domain is Ash-native either way; the canonical log just needs to carry the envelope and guarantee
append-only ordering. Record the decision and the spike findings in `SUBSTRATE.md`.

---

## 2. What to build (the substrate, in order)

### 2.1 The signed event log (foundation)
- Append-only event store; each event = `{type, payload, author_pubkey, prev_hash, sig, ts}`,
  canonical-CBOR-encoded, Ed25519-signed, hash-chained (`prev_hash`) so the log is tamper-evident.
- Verify-on-append: reject events with bad signatures or broken chain.
- Deterministic replay: replaying the log reproduces all derived state exactly. **Property test:
  replay(events) is deterministic and order-stable.**

### 2.2 Identity & membership lifecycle
- Member identity = a public key (+ rotation support). Entities/classes per `master_design §3`
  (carriers' co-op, workers' co-op, mechanics' co-op; locality chapter tag from day one for the
  multi-tenant/chapter design — see §3 below).
- Membership state machine (AshStateMachine): `invited → probationary → member → {departed |
  retired | floor-exited}`. Exhaustive, explicit transitions; each transition a signed event.
- **Dual membership** supported: a person-key may hold membership in >1 entity (per
  `master_design §3`), one vote per body, never two in one body. Model membership as
  (person, entity, class), not a single global role.

### 2.3 Capital accounts (the accrual engine)
- Per-member internal capital account = pure fold over that member's patronage events.
  `account(member, asOf) = fold(accrual_rule_vN, events(member, ≤ asOf))`.
- **Versioned accrual rules** — the rule is a parameter (constitutionalized, amendable by future
  consent); the function is pure and the version is recorded so historical accruals are
  reproducible. Never hardcode the formula; never mutate past accruals when a rule changes — new
  rule version applies forward.
- Real-time queryable balance (the stake view will read this later). Value = ledger arithmetic,
  never appraisal (`master_design §7`).
- Redemption schedule support (multi-year payout, sinking-fund accounting, annual cap, FIFO,
  death-to-estate) — model the data structures now even if the workflow comes later; the account
  must be redeemable by every exit type.

### 2.4 Throughput components & the participation floor (compute layer)
- Implement throughput as the **composite of rail components** per `throughput_and_floor.md §2`,
  as pure functions over signed events (delivery, settlement, match, custody, labor-hour).
- Implement the **anti-gaming rules** (`§3`): realized-and-verified-only, composite, circular/
  self-dealing netting, per-counterparty cap. These are deterministic graph/aggregate checks over
  the (privately-held) transaction graph.
- Implement the **floor** as: `cleared?(member, window) = throughput(member, window) ≥ threshold_vN`
  — per class, generous threshold, rolling window, with cure/hardship state in the membership
  machine. Pure, versioned, reproducible.
- **Do NOT hardcode weights/thresholds/caps/window** — they are constitutionalized parameters
  (config + versioned, amendable). Ship sane illustrative defaults clearly marked as placeholders.

### 2.5 Aggregate computation (system throughput, pool totals)
- System throughput and pool aggregates = sums over members' contributions. Implement behind the
  **privacy interface (§4)** so the summation can be plaintext-trusted-operator now and additive-HE
  later without changing callers.

---

## 3. Multi-tenant / chapter from day one (cheap now, expensive to retrofit)

Per `master_design §11` and `governance §9`: tag every event and entity with a **chapter id** and
design queries/state as chapter-scoped, with a federation scope above. You are NOT building the
federation features now — but the *data model* must make a second locality join as an equal
chapter, not a schema migration. One chapter exists at first; build as *a* chapter, not *the*
center.

---

## 4. The privacy interface (stage the crypto, don't block on it)

Per `privacy_architecture.md §6` (honest limits & staging): the heavy primitives (ZK/MPC/HE) are
**staged in behind interfaces**, starting from a *trusted-but-auditable* implementation.

Define these interfaces now; implement the simplest correct backing first:

- `Proof` — `prove(fact, private_inputs) → proof` / `verify(fact, proof) → bool`.
  *Day-one impl:* trusted-but-auditable computation that asserts the fact against the ledger and
  logs auditably. *Later:* real ZK circuits (floor-cleared, delivery, custody, eligibility).
- `Aggregate` — `sum(contributions) → total`. *Day-one impl:* plaintext sum by an auditable
  operator. *Later:* additive HE over encrypted contributions.
- `JointCompute` — `match(inputs_per_party) → results_per_party`. *Day-one impl:* trusted
  operator. *Later:* MPC. (Not needed for substrate; define the seam so network features slot in.)

**Requirement:** callers depend only on the interface. Swapping the backing implementation must
require **zero changes** to capital-account, throughput, floor, or membership code. This is the
single most important architectural decision in the hand-off — get the seam right and the privacy
roadmap is unblocked; get it wrong and the crypto migration means a rewrite.

**The NIF vs sidecar boundary is a hard safety rule (a NIF crash kills the whole BEAM VM):**
- **Plain NIF OK** (small, deterministic, bounded-input): canonical encoding, hashing, Ed25519
  verify, small Paillier arithmetic, proof *verification*.
- **Dirty-scheduler NIF only, with fixed input-size caps** (Rustler recommends dirty schedulers
  for anything >~1ms): bounded crypto with capped inputs.
- **Sidecar only** (gRPC/HTTP, never in-VM): ZK *proving*, MPC engines, FHE evaluation, long/batch
  Paillier, anything GPU-bound, anything with untrusted variable-size input.
The BEAM is the reliability substrate; the crypto layer never gets to kill scheduler latency.

**Maturity caveat (do not overclaim):** the strong crypto libraries live in Rust/C++/Go, several
carry explicit "not production-ready / no side-channel mitigations" warnings (e.g. arkworks, and
FHE libraries). Treat every advanced-crypto backing as **threat-model-gated and audit-pending** —
ship the trusted-but-auditable implementation first (an attested enclave is a legitimate Stage-2
bridge), migrate to a cryptographic implementation only when a concrete trust requirement and an
audit budget exist. For Paillier specifically, the hard part is **threshold decryption and
key governance** (§4.5), not the homomorphic addition.

Also: **model/LLM access is out of scope for the substrate** (the substrate is deterministic
domain logic, no model calls). When agentic tools are built later they follow `privacy §5`
(self-hosted/minimized) — the substrate must not embed any model dependency.

### 4.5 Key governance is constitutional, not an implementation detail
Threshold decryption shares, signing-key custody, and key rotation are **member-governance
questions**, not config (see §4a below). The substrate must structure keys so that *who holds
what* is explicit and changeable by the governance process — never hardcoded to one operator.
**Do not overbuild threshold cryptography before the event substrate exists.** The precise rule:
*no long-term architecture may depend on a single operator-held decryption key.* Day-one trusted
implementations (ordinary app/DB encryption) may exist, but **only behind the privacy interfaces,
labeled temporary, and never leaking into domain logic** — so threshold/multi-party holding can
replace them later without a rewrite. (This is a Phase 1D concern, not 1A.)

---

## 4a. Substrate governance — the constitutional rules (specify, even if enforcement comes later)

For a *member-owned* platform, control over the substrate itself is constitutional. The substrate
must make these **explicit and governable**, not implicit in whoever runs the server. Capture each
in `SUBSTRATE.md` with the answer (even if the enforcing workflow is built later, the data model
and key structure must not foreclose it):

- **Who can rotate signing keys?** (and how rotation is recorded in the log itself)
- **Who can authorize a schema / canonical-profile migration?** (`CoopEventCanonicalV1` → `V2`)
- **Who can publish checkpoints** (signed tree-heads / hash-chain roots), and where are they
  published *outside* the primary database so the operator can't silently rewrite history?
- **Who holds decryption shares?** No *long-term* dependence on a single operator-held key; design
  toward threshold/multi-party holding so no single party — including the platform operator — can
  decrypt member data alone. (Day-one trusted encryption is allowed behind the interface, labeled
  temporary; threshold crypto is Phase 1D, not 1A — don't overbuild it early.)
- **What is exported to a member when they leave?** (their own data, portable)
- **What is *never* put in the append-only log?** (raw secrets, others' private data, anything that
  can't be redacted later — the log is forever)
- **What is encrypted vs. redactable vs. tombstoned vs. merely corrected?** Corrections/reversals
  are *new events*, never mutations (the Open Collective model: append a correcting entry; soft-
  delete marks, never removes). Sensitive-but-removable data is referenced from the log, not
  embedded, so it can be erased without breaking the chain.

These are anti-capture invariants applied to the substrate (`governance.md §10`): no operator, not
even the founder, can rewrite the record, decrypt members unilaterally, or migrate the protocol
without the governance process. **Build so these remain possible; do not foreclose them.**

---

## 5. Out of scope (do not build now)

The dispatch/back-office agentic tool; the stake-view UI; the invite/recruitment flow; network
features (backhaul exchange, trailer pool, procurement); the governance/consent state machine and
voting; payroll; real ZK/HE/MPC implementations; the federation layer; any LLM integration. These
all *read from* the substrate and come in later cold-start steps. Build the substrate to *support*
them (interfaces, data model, chapter tags) without *implementing* them.

---

## 6. Acceptance criteria (TDD targets, grouped by phase — each phase gates the next)

### [1A] Canonical signed event protocol + append-only log — *blocking; nothing else starts until these pass*
1. **Canonical encoding frozen:** `CoopEventCanonicalV1` is specified; committed test vectors
   (event → exact bytes → signature) pass against an independent (Rust) verifier; property tests
   prove byte-stability across construction order.
2. **Ed25519 self-test:** startup asserts `:eddsa` support, signs/verifies a known vector, matches
   the cross-language verifier, and **fails boot** on mismatch.
3. **Envelope V1 + signing rule:** events use Event Envelope V1; the signature covers the
   canonical encoding of the envelope *without* `sig`; verification re-encodes and checks.
4. **Append-only & tamper-evident:** any mutation or out-of-chain insert is rejected; property
   tests confirm **both** the global and per-stream hash chains detect tampering.
5. **Signature integrity:** events with invalid Ed25519 sigs are rejected before persistence.
6. **Deterministic replay:** replaying events reproduces a trivial projection identically;
   replay is order-stable and independently testable.
7. **Corrections, not mutations:** no code path edits or removes a past event; corrections/
   reversals are new appended events; soft-delete marks but never removes (test the original
   survives, chain-valid).
8. **Chapter id required** on every event (schema-enforced).
9. **Key-rotation event** is representable and recorded in the log.

### [1B] Membership + capital accounts
10. **Membership lifecycle:** exhaustive state-machine transitions, each a signed event; dual
    membership across entities works; floor-exit/retire/death-to-estate all reach
    redeemable-account states.
11. **Capital-account fold:** pure function of (events, rule version); changing a rule version
    doesn't mutate historical results; placeholder redemption structures present; any member's
    balance reproducible from events alone by independent computation.

### [1C] Throughput/floor + privacy seams *(start with minimal pure folds + interface stubs)*
12. **Pure, versioned compute:** throughput/floor are pure functions of (events, rule version);
    parameters are placeholder-marked and externally configurable. (Full anti-gaming logic
    accretes later; v0 is a minimal fold.)
13. **Privacy seam swap:** capital/throughput/floor/aggregate code calls only the privacy
    interfaces; swapping the `Aggregate` backing (plaintext ↔ stub "encrypted") needs **zero
    caller changes**.
14. **No-surveillance:** no API path returns one member's detail to another; only own-data and
    system-aggregates are exposable (test the absence).

### [1D] Chapter scoping, checkpoints, governance/key structure
15. **Chapter-scoping (full):** queries chapter-scoped; a second chapter added with no schema
    change; a federation-level aggregate spans both via the `Aggregate` interface.
16. **Checkpoints externalizable:** signed global head (and optional tree root over stream heads)
    can be emitted, published outside the primary DB, and independently verified.
17. **Key governance not foreclosed:** the data model permits threshold/multi-party decryption and
    has no *long-term* single-operator-key decrypt dependency; canonical-profile migration path
    and member-export semantics are specified. (Enforcement workflow may follow; the structure
    must permit it now.)

---

## 7. Deliverables

- The Elixir/Ash substrate app: event store, signing/canonical-CBOR, identity/membership state
  machine, capital-account engine, throughput/floor compute layer, privacy interfaces with
  day-one trusted-but-auditable backings, chapter-scoped data model.
- The test suite proving every §6 acceptance criterion (TDD — tests accompany each module).
- A short `SUBSTRATE.md` documenting: the event schema, the rule-versioning approach, the privacy
  interfaces and how to swap backings, the chapter model, and the configurable
  (constitutionalized) parameters with their placeholder defaults flagged.
- A running, replayable demo: seed a chapter, a few members, some throughput events; show capital
  accrual, a floor evaluation (cleared + cure-needed cases), and a system aggregate — all
  reproducible from the event log.

---

## 8. Guardrails for the agent

- **When a design question arises, consult the spec named in §0/§ references — do not invent
  policy.** If the specs don't answer it, flag it for a human decision; don't guess on
  governance/economic/privacy semantics.
- **Never break an invariant (§0) to ship a feature.** Stop and flag.
- **Keep the crypto behind interfaces** (§4) — do not couple domain logic to any specific
  cryptographic implementation.
- **Mark every illustrative number as a placeholder** (weights, thresholds, caps, windows, rates)
  — none are real values; they are configurable and await constitutionalization.
- **TDD throughout**; pure/total functions for all computation; immutable/declarative style.
