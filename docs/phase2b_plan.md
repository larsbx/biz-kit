# Phase 2B — The D instrument as versioned data + capture surfaces

> **Status: COMPLETE** (2026-07-11). Scope was the Harness-D brief's Phase 2B
> (`docs/handoff_harness_d.md` §2); acceptance **[2B]** passes: instrument versions
> round-trip hash-identical with question-level diffs (a content change without a version
> bump is structurally impossible); synthetic interviews produce typed findings with
> provenance (2A machinery, exercised throughout); machine-extraction proposals are
> demoted via the existing `CorrectionRecorded` with the original event and both chains
> untouched; a recording without recording consent is unrepresentable. Also shipped:
> frontier-model use unrepresentable until a dated-trigger `FrontierModelUseDeclared`
> (08 §7). Gate honored: [2A] passed before this began. Normative outer authority:
> `docs/corpus/11_HARNESS.md` §1.2/§4-D/§6.3, 08 §7, SUBSTRATE.md §7. Phase 2C is next.

## §0 Spine

```
instrument        = content-addressed data, never code: tree → Canonical bytes → hash;
                    published by InstrumentVersionPublished (2A gate: monotonic versions);
                    question changes are diffable events (11 §6.3 anti-contamination)
artifacts         = out-of-log, content-addressed, verify-on-read; the log holds hashes
recording intake  ⇐ consent.recording — structural, not procedural
machine extraction = a PROPOSAL event (never authoritative state, 08 §7), corrected or
                    demoted by the existing CorrectionRecorded — history untouched
frontier model    ⇐ a prior FrontierModelUseDeclared (dated trigger) — else unrepresentable
```

## Settled decisions

- **`Harness.Artifacts`** — the out-of-log store the never-in-log rule (SUBSTRATE.md §7)
  has implied since 1A: `put(binary) → {:ok, sha256}`, `get(hash)` with hash re-verified on
  read (a tampered artifact fails closed). Filesystem-backed, content-addressed filenames,
  directory from app env (`:artifact_dir`). Access control on `get` is
  middleware-shaped (classification: `:bilateral`), like every own-data query.
- **`Harness.Instrument`** — the question tree as pure data: `validate/1` (unique question
  ids, known personas/sections, follow-up refs resolve), `hash/1` via the frozen canonical
  profile, `publish/3` (validate → store artifact → append `InstrumentVersionPublished`
  with the next version), `fetch/3` (event stream → artifact → decoded tree, hash-checked),
  `diff/2` (added/removed/changed question ids — the reviewable unit of 11 §6.3).
  `seed_d/0` carries the v1 D instrument content from corpus 11 §4-D — the trust-boundary
  question ("what would you let software accept on your behalf, and where exactly does
  trust stop?") is its core; publishing it is the operator's act, not a migration.
- **Recording consent is structural**: `DocumentCollected` with `doc_kind: "recording"`
  is rejected unless the interviewee's consent carries `recording: true`. No separate
  recording event type — a recording is a collected artifact like any other.
- **Machine extraction is a proposal, never a finding** (08 §7):
  `MachineExtractionRecorded{proposal_id, interview_ref, artifact_hash, model_ref,
  proposals}` — steward-signed (the operator runs the model), bilateral, carrying the raw
  artifact's hash. It is G1-shaped machine output; a human promotes accepted proposals by
  appending ordinary `FindingExtracted` events (G2 — the *practitioner's* claim, however it
  was transcribed). Demotion/correction reuses 1A's `CorrectionRecorded` against the
  proposal's `event_hash` — zero new correction machinery, history untouched.
- **Frontier models are unrepresentable until declared**: `model_ref` prefixed
  `"frontier:"` requires a prior `FrontierModelUseDeclared` in the chapter (the 08 §7 dated
  migration trigger). **FLAGGED PLACEHOLDER**: chapter-level any-declaration is coarse —
  per-purpose binding tightens when real model use exists; self-hosted refs are the
  unprefixed default.
- **No capture UI, no speculative wrappers**: 2A's gated events ARE the capture surface;
  the only new convenience is `Harness.collect_document/5` (hash → store → append in one
  step) because artifact intake genuinely composes two systems. Chat/form flows are the
  first consumer app's concern.

## Build steps (TDD)

1. Plan doc (this file) — commit.
2. `Harness.Artifacts` (store, verify-on-read) + `:artifact_dir` config.
3. `Harness.Instrument` (validate/hash/publish/fetch/diff/seed_d) — seed content from
   corpus 11 §4-D.
4. `MachineExtractionRecorded` type + gate checks (interview source consent; frontier
   declaration; unique proposal id); recording-consent check on `DocumentCollected`;
   `Harness.collect_document/5`; fold additions (extractions, frontier declarations).
5. Tests: artifact round-trip + tamper fail-closed; instrument validate/publish/fetch/diff
   round-trip with monotonic versions; seed_d publishes and re-fetches hash-identical;
   recording without recording-consent rejected; machine extraction on revoked/unknown
   interviews rejected; frontier ref without declaration rejected, accepted after;
   correction demotes a proposal without touching history (chains verify, original event
   unchanged).
6. Acceptance [2B] recorded; status flip — commit.

## Properties

```
P1  instruments round-trip: publish → fetch reproduces a hash-identical tree; versions
    monotonic (2A gate); diffs are computable between any two published versions
P2  artifacts are content-addressed and verified on read — silent corruption fails closed
P3  a recording artifact without recording consent is unrepresentable
P4  machine output is never authoritative: proposals are events carrying the raw-artifact
    hash; promotion is an explicit human-signed FindingExtracted; demotion is a
    CorrectionRecorded — nothing mutates
P5  a frontier model_ref without a prior dated-trigger declaration is unrepresentable
P6  all 2A consent/gate semantics hold unchanged over the new types
```

## Adversarial

Tampered artifact under a valid hash (verify-on-read) · instrument "fix" smuggled without a
version bump (content-addressing: changed tree ⇒ changed hash ⇒ new publish or no fetch) ·
recording laundered as `doc_kind: "notes"` (flagged — content inspection is not v0; the
predicate binds the declared kind) · extraction proposal on a never-consented interview ·
frontier use before declaration · proposal edited in place (append-only; corrections only).

**Gate:** 2C (synthesis + spec compilation) starts only when [2B] passes.
