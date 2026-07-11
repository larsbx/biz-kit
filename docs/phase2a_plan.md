# Phase 2A — Harness event substrate: types, consent machine, the gate

> **Status: IN PROGRESS** (2026-07-11). Scope is the Harness-D brief's Phase 2A
> (`docs/handoff_harness_d.md` §2); acceptance = brief items **[2A]**. Gate honored: the
> substrate hand-off (1A–1D) passed in full before this began. Normative outer authority:
> `docs/corpus/11_HARNESS.md` (P1–P7), 08 §4/§7, 10 §0, 12 §4.

## §0 Spine

```
gate(D) ⇔ interviews(D) ≥ n_D ∧ corroborated_core(D) ≥ c_D ∧ documents(D) ≥ d_D
         ∧ SpecAdopted(D) ∧ FixtureSetPublished(D)          — a pure fold of the log
n_D, c_D, d_D   from CharterConstantDeclared events; undeclared ⇒ gate fails closed
consent          = interviewee-signed grant {classes, recording}; revocation atomic:
                   a revoked source ceases to exist for EVERY fold and count
build(D) event   without gate(D) — unrepresentable
voice_agent      not in the interview-mode set — [LEGAL] gate encoded structurally
```

## Settled decisions

- **Interviewees sign their own consent** (11 §1.2 "consent is the interviewee's
  signature"): a per-interviewee keypair is generated at scheduling; `InterviewConsentGranted
  {interviewee_ref, pubkey, key_id, classes, recording}` is **self-certifying** (the
  `MemberRegistered` pattern — the interviewee-role signer must be the declared key), and
  `InterviewConsentRevoked` must be signed by that key. Interviewees are not members;
  `interviewee_ref` is pseudonymous.
- **One grant per interviewee_ref; revocation is terminal** — re-participation is a new
  ref with fresh consent. **FLAGGED PLACEHOLDER**: re-grant semantics (and whether old
  findings can be re-included) are a governance/consent-policy question; terminal-revocation
  is the strictest reading of 11 P5 and the cheapest correct v0.
- **Atomic exclusion is computed, not stored**: folds never delete; every count and
  corroboration is computed *excluding* revoked sources at fold time — `corroborated_core`
  counts claims whose **non-revoked, independent** sources still reach `c_D`, so revoking a
  load-bearing interviewee flips downstream state in the same transaction (11 P5).
- **Gate constants ride `CharterConstantDeclared`** (first real consumer of the 1A type):
  names `harness/D/n · harness/D/c · harness/D/d`, integer values, latest declaration wins;
  gate evaluation with any of the three undeclared returns a distinct
  `:constants_undeclared` failure — declared before first evaluation, retro-fit void
  (00 Art. IV.2).
- **Fourteen new event types** (registry + validity; consent-gated where sourced from an
  interview): `InterviewConsentGranted/Revoked` · `ResearchBriefFiled` ·
  `InterviewConducted{section, interview_id, interviewee_ref, mode}` (mode ∈
  `call | chat | form` — `voice_agent` structurally absent pending [LEGAL]) ·
  `FindingExtracted{finding_id, interview_ref, kind ∈ the nine 11 §1.2 kinds, body}` ·
  `DocumentCollected{document_id, interview_ref, doc_kind, artifact_hash}` ·
  `ConflictFlagged{claim_ref, finding_refs}` · `Corroborated{claim_ref, finding_refs}`
  (≥ c_D findings from **distinct** interviewees — independence is a validity check) ·
  `InstrumentVersionPublished{section, version, tree_hash}` (monotonic per section) ·
  `ProcessModelCompiled{section, artifact_hash}` · `SpecAdopted{section, spec_hash,
  envelope_defaults_hash}` (**governance-signed** — H2-shaped per 11 §1.4; the 1D registry
  enforces once the chapter leaves bootstrap) · `FixtureSetPublished{section, fixture_hash,
  source_refs}` (every source consented to `anonymized_fixtures`; the *content*
  anonymization predicate is 2D) · `HonorariumAccrued` (payout gated [LEGAL]) ·
  `FrontierModelUseDeclared{purpose, metric, threshold, date}` (governance-signed; 08 §7
  dated migration trigger) · plus `BuildStarted{section}` — the marker the gate protects.
- **Grades are assigned by the fold, not carried in payloads**: a finding is G2 by
  construction (attested practitioner experience); `Corroborated` promotes the claim to G3
  (08 §4). No grade field to forge.
- **The harness state extends the existing gate fold** (`Projections.Membership`), exactly
  as obligations did in 1C — the append gate needs consent/interview/version state, and the
  Log's single-fold gate architecture stays untouched. The fold's name is now well behind
  its contents; renaming it (`Projections.Gate`) is deferred cosmetics, flagged.
- Raw artifacts (recordings, documents, spec/fixture bundles) live **outside the log**,
  hash-referenced (`SUBSTRATE.md` §7 never-in-log rule); 2A carries the hashes only.

## Build steps (TDD)

1. Plan doc (this file) — commit.
2. Constants (`consent_classes`, `harness_sections`, `interview_modes`, `finding_kinds`)
   + the fourteen registry entries + `BuildStarted`.
3. Gate-fold extension: consent registry, per-section interview/document/corroboration/
   artifact state, charter-constant capture; `gate/2` + `gate_counts/2` queries with
   revocation-exclusion semantics.
4. Validity checks (consent self-certification and key-checked revocation; consent-active
   sourcing; independence on `Corroborated`; monotonic instrument versions; adoption after
   compilation; fixture source-consent; `BuildStarted ⇐ gate`).
5. Tests: consent lifecycle + wrong-key/double-grant/post-revocation rejections;
   `voice_agent` unrepresentable; independence; the end-to-end synthetic run — declare
   constants, n_D interviews with findings/documents, c_D corroborations, compile, adopt
   (governance-signed), publish fixtures ⇒ `gate(D)` true, `BuildStarted` lands; revoke a
   load-bearing source mid-log ⇒ gate false on replay and `BuildStarted` rejected; as-of
   reproducibility.
6. Acceptance [2A] recorded; status flip — commit.

## Properties

```
P1  gate(D) is a pure, as-of-reproducible function of (log, declared constants);
    undeclared constants fail closed with a distinct reason
P2  consent: grants self-certified, revocations key-checked, one grant per ref,
    revocation terminal; post-revocation sourcing unrepresentable at append
P3  revocation excludes a source from EVERY fold and count at fold time (nothing stored
    that survives it); corroborations recount against surviving sources
P4  Corroborated requires ≥ c_D findings from distinct, consent-active interviewees
P5  BuildStarted(section) without gate(section) is unrepresentable
P6  voice_agent mode, un-consented fixtures sourcing, and grade-carrying payloads are
    unrepresentable
P7  replay determinism holds for the extended gate fold (restart-rebuilt, batch-visible)
```

## Adversarial (seeded per 08 §9)

Forged consent (foreign signer) · revocation by a non-interviewee key · finding/document
smuggled onto a revoked or never-consented interview · corroboration stuffing via one
interviewee's repeated findings (independence check) · gate gaming by declaring lower
constants after the fact (latest-declaration-wins is visible on-stream; retro-fit of an
already-true gate is a governance audit question — flagged) · fixture publication citing a
synthesis-only consent · `BuildStarted` raced ahead of adoption (batch-order visibility
holds — event N sees N−1).

**Gate:** 2B (instrument + capture) starts only when [2A] passes.
