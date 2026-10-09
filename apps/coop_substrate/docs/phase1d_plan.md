# Phase 1D — Chapter scoping (full), external checkpoints, governance/key structure

> **Status: COMPLETE** (2026-07-11). All build steps done; acceptance items [1D] 15–17 pass
> (`mix test` green; `cargo test` green — checkpoints reuse the frozen canonical profile).
> Results in SUBSTRATE.md §15–§16. Deviations from this plan, minor and flagged there:
> proof signing takes an explicit `sign_with: {key_id, seed}` (the seed is never in the
> log, so "once a checkpoint key is declared" is necessarily caller-supplied), and whether
> verifiers demand signed proofs post-bootstrap is left as verifier policy. This closes the
> substrate hand-off (phases 1A–1D); kept as the record of scope.

## Grounding

Normative corpus (`tmp/freight_coop_corpus/corpus/`, untracked):

- **08_PLATFORM** — §1 (per-owner sovereign streams; signed log export as the external
  evidence path; lax-direction terminates in a human signature), §9 ("no long-term
  single-operator-key dependence — threshold custody deferred until scale warrants;
  premature cryptographic overbuild is itself a defect"), §10.3 (key rotation / social
  recovery UX: open).
- **04_ENTITIES** — §7 the Operator as a *typed capability set*, appointment/succession as
  governance events + key ceremony; the role is stateless.
- **00_CONSTITUTION** — Art. IV (governance events; constants declared before evaluation),
  Art. VI (altering append-only history is in the protected-objectives class — checkpoints
  are the detection mechanism for exactly that).
- **09_SHARIA_GOVERNANCE** — §1: federation-vs-chapter scope; stays open (below).

The hand-off's §4a questions are already answered in SUBSTRATE.md §7 (captured in 1A,
extended in 1B); 1D turns two of those answers from prose into mechanism (who may author
key events; checkpoints) and leaves the rest as specified structure.

## §0 Spine

```
role_keys(chapter, role)  = fold(governance events ≤ t)        — the key registry is a fold
declare(genesis)          = trust-on-first-use, once, flagged  — thereafter: governance-signed
enforce(role)             ⇔ role_keys(role) ≠ ∅                — bootstrap closes irreversibly
checkpoint                = sign_role(:checkpoint, {global_seq, global_hash})
                            — lives OUTSIDE the log; publishing it commits the operator
                              to the entire history (00 Art. VI detection)
federation aggregate      = Privacy.Aggregate.sum over chapters — a computation, never an event
```

## Settled decisions

- **Chapters stay implicit; the federation is a computation.** A chapter today is its id —
  no chartering event gates it (corpus 04: chapters are sovereign; the hand-off §3 asks only
  that a second locality join with no schema change, which the chapter-keyed folds already
  give). Chartering as a governance workflow, and the *representation* of federation-scoped
  events (09 §1: pseudo-chapter vs scope field), stay open — v0 federation reach is
  aggregate-only: `Throughput.federation_value(chapters, window)` sums chapter contributions
  through the existing `Privacy.Aggregate` seam (acceptance 15's third clause).
- **Role-key registry as a fold, genesis by trust-on-first-use.**
  `RoleKeyDeclared{role, key_id, pubkey, member_id?}` (and `RoleKeyRevoked{role, key_id}`)
  on the chapter's `governance` stream. Gate:
  - The **first** `RoleKeyDeclared` for role `"governance"` in a chapter is **genesis**:
    self-certifying (the declared key must be the signer, exactly the `MemberRegistered`
    pattern), accepted trust-on-first-use. **FLAGGED**: TOFU is the bootstrap trust
    assumption; publishing the genesis checkpoint (below) is its mitigation.
  - Every subsequent `RoleKeyDeclared`/`RoleKeyRevoked` (any role) must carry a
    `governance`-role signature matching a **current** governance key.
  - A role may hold **multiple concurrent keys** — the structure threshold/multi-party
    custody needs (acceptance 17), without building threshold crypto (08 §9).
  Roles now: `"governance"`, `"steward"`, `"checkpoint"`. Revoking the last governance key
  is rejected (a chapter cannot orphan its own governance).
- **Bootstrap-then-enforce, irreversibly.** While a chapter has **no** declared keys for a
  role, signatures in that role are unchecked — exactly today's 1B/1C behavior, now named
  *bootstrap mode*. The first declaration for a role closes the door: from then on every
  signature in that role must match a currently declared key. Deterministic, log-pure, and
  the 151-test corpus keeps passing un-rewritten (existing tests run in bootstrap).
  **FLAGGED PLACEHOLDER**: *which member* may act under a role key (steward-per-entity,
  operator capability classes per 10 §2) remains governance semantics; 1D binds role → keys,
  not role → persons.
- **`KeyRotated` finally gated — self-rotation.** For a **registered** member, `KeyRotated`
  must be signed by the member's *current* key (and `old_key_id` must match it); rotations
  for unregistered ids stay inert-and-ungated (1A compatibility; ChapterStats still counts
  them). Governance-recovery rotation (lost key, social recovery — 08 §10.3) is out of
  scope, flagged; the event shape doesn't foreclose it (a future governance-signed variant).
  Existing tests that rotate with an arbitrary `"author"` signer are updated to sign with
  the current member key — that diff **is** the acceptance evidence.
- **Checkpoints: emit + independently verify; publication is ops** (acceptance 16).
  `Log.checkpoint(seed)` → a self-contained blob: the canonical encoding of
  `{schema: "CheckpointV1", chapter?: nil, global_seq, global_hash}` plus an Ed25519
  signature by a declared `checkpoint`-role key. `Log.verify_checkpoint(blob)` re-derives
  the head at `global_seq` from the ledger (or a full export), checks hash equality, and
  validates the signature against the role registry — a tampered ledger fails, a checkpoint
  signed by an undeclared key fails. Where the blob is published (git, another host, a
  member's phone) is operational; the deliverable is that it is *externalizable and
  independently verifiable*. The optional tree root over stream heads is **deferred**
  (YAGNI until partial verification or sync needs it — flagged).
- **Proofs gain their signature** (closes the 1C §13.5 flagged deviation): once a
  `checkpoint` key is declared, `Privacy.Proof.TrustedAudit` signs `{fact, as_of}` with it
  and `verify` checks the signature *and* recomputes; in bootstrap it stays unsigned exactly
  as today. Same key as checkpoints: both are strict-direction attestations of log state.
- **Explicitly NOT in 1D** (each flagged in SUBSTRATE.md §8): threshold/multi-party key
  custody (08 §9 — until scale warrants); social-recovery UX; federation-scoped *events*;
  chapter-chartering workflow; query-authn middleware (needs the first consumer API
  surface); floor/redemption enforcement workflows; packaged member-export workflow.
  Canonical-profile migration and export semantics stay **specified** (SUBSTRATE.md §7),
  which is all acceptance 17 asks of them.

## Build steps (TDD — tests with/before each module)

1. **Plan doc** (this file) — commit.
2. **Federation aggregate + full chapter-scoping tests** (acceptance 15):
   `Throughput.federation_value/3` (chapters list → Aggregate seam); tests: two chapters
   populated side by side with zero schema/registry change, chapter isolation reconfirmed,
   federation total spans both, classification test extended (`:aggregate`).
3. **Role-key registry**: `RoleKeyDeclared`/`RoleKeyRevoked` types (governance stream);
   registry state in the gate fold (`role_keys`); gate checks (genesis TOFU
   self-certification; governance-signed thereafter; last-governance-key revocation
   rejected; bootstrap-then-enforce for `steward` signatures on all existing steward-role
   types). Tests: genesis, post-genesis declaration without governance sig rejected,
   steward enforcement closing over a live log, revocation, multiple keys per role.
4. **`KeyRotated` gate**: self-rotation by current key for registered members; update the
   existing rotation call sites in tests to sign correctly.
5. **Checkpoints** (acceptance 16): `Log.checkpoint/1` + `Log.verify_checkpoint/1`;
   tests: round-trip verify; tamper the ledger (raw-SQL helpers from `LogCase`) → verify
   fails; undeclared signer → fails; verification from a fresh recovery (restart) passes.
6. **Signed proofs**: `TrustedAudit` signs when a checkpoint key exists; verify checks
   signature + recomputation; bootstrap unchanged. (Closes SUBSTRATE.md §13.5 deviation.)
7. **SUBSTRATE.md §15–§16** (chapter/federation posture, role-key registry + bootstrap
   doctrine, checkpoint format, updated §7 answers, §8 open-question moves, §9 additions),
   README/quickstart status — commit.

## Properties

```
P1  a second chapter joins with zero schema/registry/code change; chapter isolation holds
P2  federation aggregates route through the Aggregate seam; only totals cross chapter lines
P3  role_keys is a pure fold; genesis is TOFU once per chapter (flagged), every later
    declaration/revocation carries a current governance-key signature
P4  enforce(role) ⇔ keys declared: bootstrap mode is namable, and closing it is irreversible
    (no event un-declares the last governance key)
P5  registered-member KeyRotated is signed by the member's current key; rotation chains
    (old_key_id must match) — hijack by foreign key unrepresentable
P6  checkpoint verification = recomputation + registry signature check; ledger tampering or
    an undeclared signer fails it; a published checkpoint commits the operator to history
P7  no decryption key exists anywhere; roles hold N keys (threshold structure not foreclosed)
P8  every gate decision and fold remains a pure function of the log (replay-identical)
```

## Adversarial suite

Genesis race (attacker declares governance first on a fresh chapter — TOFU accepted by
construction: flagged, mitigated by publishing the genesis checkpoint out-of-band) · rogue
steward signature after the registry closes → rejected · declaration signed by a revoked or
rotated-out governance key → rejected · revoke-last-governance-key → rejected · rotation
hijack (foreign key, stale old_key_id) → rejected · checkpoint signed by non-declared key →
verify false · operator rewrites history post-checkpoint → published blob mismatches on
recomputation (detection is the mechanism, 00 Art. VI) · proof re-signed under a revoked
checkpoint key → verify false against the registry as-of.

## Acceptance / verification (hand-off §6 [1D] items 15–17)

- **15** two-chapter tests + `federation_value` through the seam; no schema change.
- **16** checkpoint emit/verify round-trip; tamper detection; external verifiability from
  an export/fresh recovery.
- **17** role registry holds N keys per role (threshold not foreclosed); zero decryption
  keys exist; migration path + member-export semantics remain specified (SUBSTRATE.md §7).
- `mix test` green (incl. all 1A–1C suites, rotation call sites updated); `cargo test`
  green (checkpoint uses the existing canonical profile — no encoding change).

**Gate:** the substrate hand-off is complete after 1D; anything further (workflows,
consumer surfaces) is a new brief.
