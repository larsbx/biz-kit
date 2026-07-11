# Phase 2C — Synthesis, spec compilation, adoption binding

> **Status: IN PROGRESS** (2026-07-11). Scope is the Harness-D brief's Phase 2C
> (`docs/handoff_harness_d.md` §2); acceptance = brief items **[2C]**. Gate honored: [2B]
> passed before this began. Normative outer authority: `docs/corpus/11_HARNESS.md`
> §1.3–§1.4 (synthesis, spec compilation, adoption), `docs/corpus/10_AUTONOMY.md` §0–§2
> (the H-set predicate; unclassified ⇒ block), 09 §1 (contested ⇒ N).

## §0 Spine

```
model(section, as_of) = pure function of (log, consent state) — recompilable by anyone;
                        published as a content-addressed artifact (ProcessModelCompiled)
conflicts             surface in the model verbatim — never averaged away (11 P4)
spec = f(model, classifier); tier(node): H1–H6 ⇒ R · contested ⇒ N ·
                        ∉H ∧ enveloped ⇒ A · unclassified ⇒ block (10 §0, fail closed)
∀ spec node: finding-provenance resolves within the model (11 P1, checked mechanically)
SpecAdopted binds the model: payload gains model_hash; a mismatch with the latest
                        compiled model is unrepresentable
```

## Settled decisions

- **The model is recompilable, not curated**: `Harness.Synthesis.compile_model/3` builds
  `ProcessModelV1` from raw log reads (bodies are not in the gate fold) + the gate fold's
  consent/corroboration state, deterministically sorted throughout — so
  `publish_model` → fetch → recompile is **byte-identical**, and selective compilation
  (13's demo-asset cherry-picking, here as evidence cherry-picking) is detectable by
  anyone. `as_of:` supported.
- **Model contents (v0, mechanical)**: `core` = corroborated claims surviving consent
  (finding refs, kinds, verbatim bodies, distinct-source counts — G3 by construction);
  `conflicts` = flagged claims verbatim; `observations` = G2 findings outside any core
  claim (visible, marked — never silently dropped); `exceptions` = all exception-kind
  findings (the adversarial seed, 11 §0: horror stories become tests); `durations` and
  `documents` summaries; `envelope_default_candidates` = core claims containing a
  `workaround`/`tool` finding — **FLAGGED PLACEHOLDER** heuristic; real candidate
  selection is synthesis judgment reviewed at adoption.
- **Consent class covers the use** (11 P2): the model includes only findings whose
  interviewee granted `synthesis` and remains active — a source without the class, or
  revoked, is excluded from every model section including conflicts.
- **The classifier is data, reviewed at the signature**: tier assignment needs act
  semantics findings don't carry, so `compile_spec(model, classifier)` takes an explicit
  per-claim classifier map — `%{"h" => "H1".."H6"} ⇒ R`, `"contested" ⇒ N` (09 gated-N),
  `%{"enveloped" => true} ⇒ A`, **anything else ⇒ block** (10 §0: unclassified acts fail
  closed, never default to A). The classifier is embedded in the spec artifact — the
  operator's judgment is exactly what the one human signature reviews.
- **Adoption binds the model**: `SpecAdopted` gains a required `model_hash`; the gate
  rejects adoption unless it equals the latest compiled model's artifact hash (the fold
  now stores the hash, not a boolean). Registry evolution is safe pre-production; the 2A
  end-to-end test is updated accordingly — flagged, not silent.
- **Two artifacts out of compilation**: the spec (`WorkflowSpecV1`: nodes with tiers +
  provenance, adversarial cases seeded from exceptions, the embedded classifier, skeleton
  P-properties) and the envelope-defaults document (`EnvelopeDefaultsV1`, from the model's
  candidates) — `SpecAdopted` signs both hashes plus the model's.
- **No adoption helper**: the governance signature is a plain gated append — sugar would
  only obscure whose act it is.

## Build steps (TDD)

1. Plan doc (this file) — commit.
2. `SpecAdopted` payload + gate binding (`model_hash` required, must match the fold's
   latest compiled hash); fold stores the model artifact hash; 2A test updated.
3. `Harness.Synthesis`: `compile_model/3` (pure, sorted, consent-filtered),
   `publish_model/4` (encode → artifact → gated event), `compile_spec/2` (pure),
   `publish_spec/5` (fetch latest model → compile → two artifacts → hashes).
4. Tests: deterministic recompilation equals the published artifact; consent filtering
   (no-synthesis-class and revoked sources excluded everywhere); conflicts surface;
   observations never dropped; provenance closure (every spec node's finding_refs resolve
   in the model — the mechanical 11 P1 check); tier totality incl. unclassified ⇒ block
   and contested ⇒ N; adoption binding (wrong/stale model_hash rejected, correct
   accepted).
5. Acceptance [2C] recorded; status flip — commit.

## Properties

```
P1  the model is a pure function of (log ≤ as_of, consent state): recompilation is
    byte-identical to the published artifact — cherry-picking is detectable
P2  only synthesis-consented, active sources appear anywhere in the model
P3  conflicts and out-of-core observations surface verbatim; nothing is averaged away
P4  tier assignment is total and fail-closed: R for H-classes, N for contested,
    A only for classified-enveloped, block otherwise
P5  every spec node resolves to finding_refs present in the model (provenance closure)
P6  SpecAdopted without the latest model's hash is unrepresentable
```

## Adversarial

Cherry-picked model (recompile-and-compare catches it) · classifier promoting an
unclassified act to A (structure: absence ⇒ block) · adoption against a stale model after
new findings shifted it (hash binding) · conflict laundering by omitting ConflictFlagged
claims from the model (they are compiled in mechanically) · synthesis including a
prospect-record-only consent (class filter).

**Gate:** 2D (fixtures + funnel) starts only when [2C] passes.
