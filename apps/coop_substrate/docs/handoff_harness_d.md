# Hand-off: Harness-D Workflow Build (Coding Agent)

**Scope of this hand-off:** build the **Harness-D machinery** — the research + interview
pipeline for section D (dispatch) that must pass before any dispatch feature is built
(`docs/corpus/11_HARNESS.md` §0: *no workflow ships from assumption*). This is step 1 of the
corpus build order (`docs/corpus/HANDOFF.md` §5: "Harness-D instrument + friendly-carrier
recruitment ← critical path"). It is NOT the dispatch tool, the matching engine, or the
stake view — the D build is a *later brief*, gated on `gate(D)` passing, and it reads the
spec/fixtures this pipeline produces.

**Substrate premise (do not rebuild it):** phases 1A–1D are complete (`SUBSTRATE.md`
§10–§16). Everything here is signed events on `CoopSubstrate.Log` through the existing
append gate, folds in the existing projection shape, constants via `CharterConstantDeclared`
or gated activation events, role keys from the 1D registry, and the privacy seams from 1C.
New event types enter the 1A type registry; log-dependent checks enter `Protocol.Validity`.

**Read before coding (in this repo):**
- `docs/corpus/11_HARNESS.md` — the normative spec this brief implements; §0 spine, P1–P7,
  and the adversarial suite bind every phase below.
- `docs/corpus/10_AUTONOMY.md` §0–§2 — the H-set predicate the spec compiler assigns tiers
  with; §4.1 order-to-cash (the D process this harness investigates).
- `docs/corpus/08_PLATFORM.md` §4 (grading/τ), §7 (LLM boundary — normative, incl. dated
  migration triggers), §9 (verification doctrine).
- `docs/corpus/12_ONBOARDING.md` §3–§5 (pitch discipline, compliance envelopes, funnel).
- `docs/corpus/13_FOUNDER_CAMPAIGN.md` §6 (the campaign consumes this pipeline's output:
  "the interview close IS the invitation for hub-scored leads").
- `SUBSTRATE.md` §7–§9, §13, §15 (what the substrate already gives you).

**Division of labor — be explicit about it in every phase plan:** the coding agent builds
the *machinery* (types, gates, folds, instrument data, extraction, synthesis, compilation,
fixtures). The founder/operator does the *field work* (recruiting 5–8 friendly carriers,
conducting interviews, collecting documents, signing adoptions). A phase is never blocked
on field work: build against synthetic interviews, and mark the gate's real evaluation as
the operator's milestone, not the build's.

---

## 0. Non-negotiable invariants (corpus 11 P1–P7 + 00/08; build-breaking if violated)

1. **The gate is the point.** `gate(D) ⇔ interviews ≥ n_D ∧ corroborated_core ≥ c_D ∧
   documents ≥ d_D ∧ SpecAdopted(D) ∧ FixtureSetPublished(D)` — a pure function of the log
   (11 P6). A D-build event without `gate(D)` is unrepresentable. Constants `n_D, c_D, d_D`
   are charter constants declared before first evaluation (placeholder-flagged; the corpus
   says n_D ≈ 5–8 — the gate kills assumption-driven builds, it does not bureaucratize a
   bootstrap).
2. **Requirements have provenance** (11 P1): every node/edge/exception in the adopted spec
   resolves to ≥ 1 finding event; every adversarial case to a reported failure or probe.
3. **Consent is sovereign** (11 §1.2, P2, P5): interview content is the interviewee's data.
   Typed consent classes — `synthesis | anonymized_fixtures | prospect_record` — granted and
   revoked by signed events; revocation is atomic (no post-revocation use in ANY pipeline
   stage); no finding enters fixtures un-anonymized. Consent checks are gate checks, not
   application courtesy.
4. **Model output is never authoritative state** (08 §7): transcription/extraction lands as
   graded verification events carrying the raw-artifact hash; raw audio/documents live
   OUTSIDE the log (hash-referenced — the log is forever, media is not); self-hosted models
   by default, frontier models only under zero-retention terms as bounded necessity with a
   **dated migration trigger declared as an event**. Poisoned-transcript injection is a
   standing adversarial case.
5. **Grade discipline** (11 §1.2, 08 §4): a single practitioner claim lands G2; `≥ c_D`
   independent interviews promote to G3 (`Corroborated`); conflicts emit `ConflictFlagged`
   and resolve grade-ordered — G3 field fact ≻ G1 document claim — logged, never smoothed
   (11 P4).
6. **One human signature per section** (11 §0, 10): `SpecAdopted(D)` is the pipeline's only
   R node (H2-shaped — it declares envelope defaults). It must be signed by a declared
   role key (1D registry); everything else is A-tier machinery.
7. **Funnel emissions carry interview provenance** (11 P7, 12 P6): the lead knows why we're
   calling. Recruitment outreach runs inside 12 §4 compliance envelopes (opt-out atomic,
   quiet hours, DNC) — build the envelope predicates before any sequence sends.
8. **Interviewee identity/edges are sovereign** (00 Art. II.3): who said what is bilateral
   between the co-op and the interviewee; published synthesis and fixtures are k-safe and
   anonymized by predicate, not by diligence.

## 1. Counsel gates before external contact ([LEGAL] — machinery may exist, use may not)

- Outbound voice-agent statutes per state (two-party consent, AI-disclosure) — voice mode
  ships DISABLED behind this gate; v0 interview modes are operator-conducted call/chat and
  the in-app guided form (11 §1.2 lists all three; only the automated-voice mode is gated).
- Honorarium treatment (tax/classification) — represent the honorarium as an event now,
  gate payout workflow on counsel.
- Recording consent per state for transcription — the consent event set must include
  recording consent distinctly from use-class consent.

## 2. Build phases (strictly in order; each ships §0 spine, P-properties, adversarial suite
per the corpus spec-shape rule)

### Phase 2A — Harness event substrate (types, consent machine, the gate)

The representability slice; no agents, no models, no UI.

- Event types (registry + validity checks; all chapter-scoped, disclosure-classed):
  `InterviewConsentGranted{interviewee_ref, classes, recording}` /
  `InterviewConsentRevoked{interviewee_ref}` (revocation atomic — a gate check, and every
  downstream fold treats revoked-source findings as nonexistent) ·
  `ResearchBriefFiled{section, artifact_hash, citations}` (G1) ·
  `InterviewConducted{section, interviewee_ref, mode, instrument_version}` ·
  `FindingExtracted{interview_ref, kind ∈ {process_step, duration, pain, workaround,
  document, rent, exception, tool, term_of_art}, body, grade}` ·
  `DocumentCollected{interview_ref, doc_kind, artifact_hash}` ·
  `ConflictFlagged{finding_refs}` · `Corroborated{claim_ref, finding_refs}` (gate: ≥ c_D
  *independent* interviewees — independence is a validity check, not a convention) ·
  `InstrumentVersionPublished{section, version, tree_hash}` ·
  `ProcessModelCompiled{section, artifact_hash}` · `SpecAdopted{section, spec_hash,
  envelope_defaults_hash}` (R: role-key-signed) · `FixtureSetPublished{section,
  fixture_hash}` · `HonorariumAccrued{interviewee_ref, amount_minor}` (payout gated) ·
  `FrontierModelUseDeclared{purpose, migration_trigger: {metric, threshold, date}}` (08 §7).
- `Projections.Harness` — the section fold: interview count, corroborated-core count,
  document count, consent state, instrument versions, adoption/fixture status. `gate(D)`
  is a query over it; `n_D/c_D/d_D` read from declared charter constants (retro-fit void).
- **Acceptance [2A]:** gate(D) is log-pure and as-of reproducible; consent revocation
  atomically excludes a source from every fold (tested by revoking mid-log and replaying);
  un-anonymized fixture publication and post-revocation use are unrepresentable; a D-build
  marker event without gate(D) is rejected at the append gate.

### Phase 2B — Instrument + capture surfaces

- The D instrument as **versioned data, not code** (11 §6.3): the adaptive question tree
  (personas: carrier-owner, dispatcher, driver; branching on role/fleet-size/tooling) is a
  content-addressed artifact published by `InstrumentVersionPublished` — question changes
  are diffable events. Seed content comes from 11 §4-D: how tenders arrive, acceptance
  factors ("what would you let software accept on your behalf, and where exactly does trust
  stop?" — the answers ARE the envelope defaults), assignment logic, tracking rituals,
  document flow, exception taxonomy.
- Capture: operator-conducted chat/form flows that emit `FindingExtracted` events directly
  (typed findings, not prose); document intake hashing artifacts into out-of-log storage.
- Extraction assist behind the 08 §7 boundary: transcription/finding-extraction proposals
  land as graded verification events referencing the raw hash; self-hosted model first;
  any frontier use requires a prior `FrontierModelUseDeclared` with its dated trigger.
- **Acceptance [2B]:** instrument versions round-trip (publish → fetch → diff); a synthetic
  interview produces typed findings with grades and provenance; extraction output is
  demotable/correctable without touching history; recording without recording-consent is
  unrepresentable.

### Phase 2C — Synthesis + spec compilation + adoption

- Corroboration fold (claims × independent sources → G3), conflict detection, and
  `ProcessModelCompiled`: DAG nodes/edges, actor/document map, duration distributions,
  exception taxonomy, envelope-default candidates *from observed practice* (11 §1.3).
- Spec compiler: process model → the D workflow spec — per-node tier via the 10 §1 H-set
  predicate (unclassifiable ⇒ block), P-properties, adversarial suite seeded from the
  exception taxonomy, envelope defaults. Output is a content-addressed artifact;
  `SpecAdopted` signs its hash (the one R signature; 1D role key).
- **Acceptance [2C]:** every compiled node resolves to findings (11 P1 checked
  mechanically); tier assignment is total and fail-closed; conflicts surface in the model
  rather than being averaged away; adoption without the compiled artifact's hash is
  unrepresentable.

### Phase 2D — Fixtures + funnel emission

- Fixture generation (11 §1.5): anonymization predicate on every artifact (redaction of
  names, MC/DOT numbers, lanes, rates — document quirks are the adversarial case);
  parser fixtures from real collected documents; fold fixtures from reported timelines;
  property-test generators bounded by observed distributions. `FixtureSetPublished` gates
  the D build alongside adoption.
- Funnel handoff (11 §3, 12 §5): each consenting interviewee emits a prospect record with
  interview provenance (carrier-owner/dispatcher → member prospect, Track D/L), consumable
  by the 12 onboarding engine and the 13 campaign — the emission seam only; outreach
  sequencing is the 12 engine's brief, not this one.
- **Acceptance [2D]:** fixture sets fail build on any anonymization-predicate violation;
  every funnel record resolves to its interview + consent class; with synthetic data for
  n_D interviews, `gate(D)` evaluates true end-to-end and flips false under consent
  revocation of a load-bearing source.

## 3. Open questions (owned here until moved)

1. `n_D, c_D, d_D` values — operator declares before first gate evaluation (placeholder
   `CharterConstantDeclared` events; corpus suggests n_D ≈ 5–8).
2. Instrument-revision signer: operator-R first (corpus 11 §6.3 recommendation), relax to
   A-with-veto-window later.
3. Honorarium vs early-member-standing split per persona (11 §6.2) — represent both.
4. Whether shipper interviews run early as Face design input or wait for S2 (11 §6.4).
5. Voice-agent mode enablement — [LEGAL] per state, §1.

## 4. Deliverables

Phase plans per the repo convention (`docs/phase2{a,b,c,d}_plan.md`, each committed before
its build; deviations flagged, never silent), the machinery green under `mix test` with the
1A–1D suites untouched, and a `HARNESS.md` (normative for the pipeline, spec-shape) whose
acceptance section maps [2A]–[2D] to tests. The corpus remains the outer authority; where
this brief and `docs/corpus/11_HARNESS.md` conflict, the corpus governs — flag it.

**Gate out:** the D build brief (dispatch agents on the first carrier's exhaust) may be cut
only when `gate(D)` is true on real, consented field data — machinery green on synthetic
data is this brief's exit; the gate's real evaluation is the founder's.
