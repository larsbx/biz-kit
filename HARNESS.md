# HARNESS.md — The Harness-D Pipeline (Normative)

Status: **machinery complete** (Phases 2A–2D, 2026-07-11; plans under
`docs/phase2{a,b,c,d}_plan.md`, brief at `docs/handoff_harness_d.md`). Normative for the
harness pipeline; the outer authority is `docs/corpus/11_HARNESS.md` (with 08 §4/§7,
10 §0, 12 §4–§5) — on conflict the corpus governs, flagged. Everything below rides the
substrate (`SUBSTRATE.md`): signed events through the append gate, pure folds,
content-addressed artifacts out-of-log, constants declared before first evaluation.

## §0 Spine

```
gate(D) ⇔ interviews ≥ n_D ∧ corroborated_core ≥ c_D ∧ documents ≥ d_D
         ∧ SpecAdopted(D) ∧ FixtureSetPublished(D)
  — a pure fold; constants from CharterConstantDeclared (harness/D/{n,c,d}, k);
    undeclared ⇒ fails closed; BuildStarted(D) without gate(D) unrepresentable

consent   = the interviewee's own signature (per-interviewee keypair, self-certified);
            classes ⊆ {synthesis, anonymized_fixtures, prospect_record} + recording flag;
            revocation is terminal and its exclusion COMPUTED by every fold and count
instrument = content-addressed data (question changes are diffable events)
model      = pure function of (log, consent) — recompilable byte-identically by anyone
spec       = f(model, classifier); tiers fail closed (unclassified ⇒ block); adoption is
            the section's ONE human signature and binds the latest model's hash
fixtures   ⇐ anonymization predicate (build failure, not review note)
funnel     = provenance-complete prospect emission under the prospect_record class
```

## 1. The pipeline, stage by stage

| Stage (11 §1) | Machinery | Enforcement |
|---|---|---|
| Consent | `InterviewConsentGranted/Revoked` — self-certified keypair, one grant per ref, terminal revocation (flagged placeholder policy) | gate: self-signature, key-checked revocation; every sourcing event requires active consent; exclusion computed at fold time |
| Research | `ResearchBriefFiled` (G1 artifact hash) | section-checked |
| Instrument | `Harness.Instrument` — validate/hash/publish/fetch/diff; `seed_d/0` carries the corpus 11 §4-D content | monotonic versions (gate); content-addressing makes an unversioned edit impossible |
| Capture | `InterviewConducted` (modes `call/chat/form` — `voice_agent` structurally absent, [LEGAL]; binds a published `instrument_version` — unversioned questions unrepresentable, 11 §6.3), `FindingExtracted` (G2 by construction, no grade field to forge), `Harness.collect_document` (out-of-log artifact, verify-on-read) | consent-gated; `doc_kind: "recording"` requires recording consent |
| Extraction (08 §7) | `MachineExtractionRecorded` — a proposal carrying the raw-artifact hash, never authoritative; promotion = human `FindingExtracted`; demotion = `CorrectionRecorded` | `frontier:` model refs unrepresentable until a dated-trigger `FrontierModelUseDeclared` |
| Corroboration | `Corroborated` (claim → G3), `ConflictFlagged` | ≥ k **distinct interviewees** (independence is a gate check), consent-active |
| Synthesis | `Harness.Synthesis.compile_model` → `ProcessModelV1` (core/conflicts/observations/exceptions/durations/documents/candidates) | pure + sorted ⇒ recompilation byte-identical; synthesis-consent filter on every section; conflicts verbatim (11 P4) |
| Spec | `compile_spec(model, classifier)` → `WorkflowSpecV1`; classifier is data, embedded, reviewed at the signature | tiers: H1–H6 ⇒ R · contested ⇒ N (09) · enveloped ⇒ A · else **block** (10 §0); provenance closure by construction |
| Adoption | `SpecAdopted` — governance-signed (H2-shaped), the pipeline's one R node | gate binds `model_hash` to the latest compiled model |
| Fixtures | `Harness.Fixtures.publish` behind `Harness.Anonymization` (regex classes + operator denylist; non-text fails closed) | any violation ⇒ unpublishable; sources need the `anonymized_fixtures` class; the denylist never enters an artifact |
| Funnel | `FunnelProspectEmitted{prospect, interviewee, interview, track}` | unique, interview↔interviewee match, active `prospect_record` consent; consumers re-check consent before contact (seam contract) |
| Build gate | `Harness.gate/3`, `Harness.counts/3`; `BuildStarted` | gate-pure, as-of reproducible, fails closed |

## 2. Properties (each enforced by the suite)

```
P1  gate(D) is a pure, as-of-reproducible function of (log, declared constants),
    failing closed on undeclared constants                      (harness_gate_test)
P2  consent self-signed; revocation key-checked, terminal, and atomically excluding
    across every fold, count, model, and emission               (harness_gate, synthesis,
                                                                 fixtures_funnel tests)
P3  corroboration requires k independent consent-active interviewees (harness_gate_test)
P4  instruments and models are content-addressed and recompilable/diffable —
    cherry-picking and silent edits are detectable              (instrument, synthesis)
P5  machine output is never authoritative; recording needs recording consent;
    frontier models need a dated declaration                    (capture_test)
P6  tiers are total and fail closed; spec provenance closes over the model;
    adoption binds the latest model hash                        (synthesis_test)
P7  fixture sets fail build on any anonymization violation; funnel records are
    provenance-complete and class-consented                     (fixtures_funnel_test)
P8  BuildStarted(section) without gate(section) is unrepresentable (harness_gate,
                                                                 fixtures_funnel tests)
```

## 3. Acceptance (brief items → evidence)

- **[2A]** gate purity, atomic consent exclusion, unrepresentables — `harness_gate_test`
  (incl. revoke-mid-log flip and `voice_agent` rejection).
- **[2B]** instrument round-trip + diff, artifact verify-on-read, proposal demotion with
  history untouched, structural recording consent — `instrument_test`, `capture_test`.
- **[2C]** provenance closure, fail-closed tiers, conflicts verbatim, model-hash-bound
  adoption, byte-identical recompilation — `synthesis_test`.
- **[2D]** predicate-blocked publication, provenance-complete consent-gated funnel, and
  the full real-machinery pipeline driving gate(D) true with revocation flipping it —
  `fixtures_funnel_test`.

## 4. Open (owned here until moved)

`n_D/c_D/d_D` values (operator declares; corpus suggests n_D ≈ 5–8) · re-grant semantics
after terminal revocation · instrument-revision signer (operator-R first) · honorarium
split + payout ([LEGAL]) · voice-agent enablement per state ([LEGAL]) · per-purpose
frontier-model binding · binary-fixture scanning (v0 fails closed on non-text) ·
envelope-default candidate selection (v0 heuristic: workaround/tool claims) · early
shipper interviews vs S2 (corpus 11 §6.4).

## 5. Gate out

The machinery is complete and green on synthetic data. `gate(D)`'s **real** evaluation is
field work: recruit 5–8 friendly carriers (13 §1 hub scoring), conduct consented
interviews, declare the constants, adopt the spec. The D build brief (dispatch agents on
the first carrier's exhaust) is cut only when `gate(D)` is true on real, consented data —
by then the spec, its envelope defaults, its adversarial suite, and its fixtures all exist
as content-addressed artifacts with finding-provenance end to end.
