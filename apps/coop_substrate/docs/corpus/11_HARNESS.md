# 11_HARNESS.md — Research & Interview Harness

Register: engineering/system terms (01). Concern: the discovery pipeline every workflow section must pass before build. Imports: grading/τ (08 §4), autonomy mechanisms (08 §3, 10), evidence-gate pattern (03). Priority order per current state: D (dispatch) → L (labor onboarding) → Y (yards & 3PL docks).

---

## 0. Spine rule

```
build(π) permitted ⇐ harness(π) complete:
    research(π) → interviews(π) → synthesis(π) → spec(π) → fixtures(π) → adopt(π)   [R]

∀ node ∈ DAG(π): provenance(node) resolves to ≥1 finding      — requirements have provenance
∀ adversarial case ∈ suite(π): ∃ reported failure ∨ probe      — horror stories become tests
interviewee(π) ∈ funnel(class(interviewee))                     — discovery IS lead-gen
```
No workflow ships from assumption. The harness is itself an autonomous workflow: one human signature per section (spec adoption), everything else A-tier.

## 1. Pipeline

### 1.1 Research (A)
Deep-research agent per section: industry baseline walk-through, regulatory surface, document inventory, actor map, rent map, reported statistics. Output: `ResearchBriefFiled` — a graded artifact (G1 document-consistent; citations are its provenance). Contradictions with field findings are expected and flagged, not smoothed.

### 1.2 Interview automation (A; consent is the interviewee's signature)
- **Instrument**: adaptive question tree per persona — carrier-owner, dispatcher, driver, yard owner, 3PL dock manager, shipper ops. Branching on disclosed role, fleet size, current tooling. Modes: voice agent ∨ chat ∨ in-app guided form; scheduling, reminders, conduct, transcription all A.
- **Extraction**: typed findings, not prose — `FindingExtracted{kind ∈ {process_step, duration, pain, workaround, document, rent, exception, tool, term-of-art}, grade}`. A single practitioner claim lands G2 (attested experience); `Corroborated` at ≥ k independent interviews promotes to G3. Conflicting findings emit `ConflictFlagged` for synthesis.
- **Artifacts**: sample documents collected under consent (rate confirmations, BOLs, lease terms, invoices) — the raw material for parsers and fixtures.
- **Consent & sovereignty**: interview content is the interviewee's data; declared consent terms per use class (synthesis ∣ anonymized fixtures ∣ registry prospect record); revocable, revocation atomic. No finding enters fixtures un-anonymized.
- **Incentive**: honorarium ∨ early-member standing; either way the close of every interview is the funnel handoff (§3).

### 1.3 Synthesis (A)
Reconcile brief × findings: corroboration-weighted (G3 field fact ≻ G1 document claim on conflict — practitioners outrank publications about practitioners). Output `ProcessModelCompiled`: DAG nodes + edges, actor/document map, duration distributions, exception taxonomy, envelope-default candidates (corridor widths, auto-accept bounds proposed *from observed practice*, not intuition).

### 1.4 Spec compilation (A) → adoption (R)
Process model compiles to the workflow spec: DAG with per-node tier assignment via the 10 §1 predicate, P-properties, adversarial suite seeded from the exception taxonomy and reported horror stories, envelope defaults. `SpecAdopted` is the section's one human signature — it declares envelope defaults, which is governance-adjacent (H2-shaped).

### 1.5 Fixture generation (A)
Anonymized interview artifacts + collected documents → TDD corpus: parser fixtures (real rate cons in the wild's actual formats), fold fixtures (reported timelines), property-test generators bounded by observed distributions. `FixtureSetPublished` gates the build alongside adoption.

## 2. Build gate

```
gate(π) ⇔ interviews(π) ≥ n_π ∧ corroborated_core(π) ≥ c_π
         ∧ documents(π) ≥ d_π ∧ SpecAdopted(π) ∧ FixtureSetPublished(π)
```
n_π, c_π, d_π: charter constants per section (04 §9). Small on purpose for D (the friendly-carrier slice needs n_D ≈ 5–8, not 50) — the gate exists to kill assumption-driven builds, not to bureaucratize a bootstrap.

## 3. The funnel unification

| Interviewee class | Findings feed | Funnel emission |
|---|---|---|
| Carrier owner / dispatcher | D spec, envelope defaults | member prospect (Track L/D) |
| Driver | D + relay design, L onboarding spec | driver-member prospect (Track L) |
| Yard owner | Y instrument, lease-term reality | registry prospect record + outbound sequence (Track Y) |
| 3PL / dock manager | Y + facility-graph schema validation | dock lease prospect (Track Y) |
| Shipper ops | Face onboarding spec, credit-line packet design | future shipper lead (S2) |

One conversation, three outputs: finding events, funnel record, and (with consent) fixture material. Marketing spend on interview recruitment is therefore simultaneously discovery spend — the "by any means" budget buys evidence and pipeline in the same transaction.

## 4. Section instruments (priority order)

- **D — dispatch**: how tenders actually arrive (email/EDI/portal/text), acceptance decision factors (the real envelope), assignment logic, tracking rituals, document flow, exception handling (breakdowns, reschedules, driver swaps). Core question: what would you let software accept on your behalf, and where exactly does trust stop?
- **L — labor onboarding**: how drivers job-search and what they distrust; qualification-document friction; what "home daily" and "stake" messaging actually lands vs bounces; referral behavior (who invites whom, why).
- **Y — yards & 3PL docks**: how owners think about idle capacity; per-drop vs term appetite; security/liability anxieties (the G2 security-bits requirement validated or revised from *their* mouths); what outreach they'd answer vs delete.

## 5. Properties

```
P1  ∀ DAG node/edge/exception in an adopted spec: finding-provenance resolves
P2  ∀ fixture: anonymization predicate holds; consent class covers the use
P3  corroboration: core process claims at ≥ c_π independent sources before adoption
P4  conflict resolution is grade-ordered and logged; silent smoothing unrepresentable
P5  consent revocation atomic: no post-revocation use in any pipeline stage
P6  gate(π) is a pure function of the log; build events without gate(π) unrepresentable
P7  funnel emissions carry interview provenance (the lead knows why we're calling)
```
Adversarial: fabricated interviews inflating corroboration (identity attestation + sponsorship on recruited interviewees), leading-question contamination (instrument versions are events; question-tree changes are diffable and reviewable), fixture de-anonymization via document quirks (redaction predicates on parser output), consent-scope creep — fail closed.

## 6. Open

1. n_π, c_π, d_π per section; voice-agent vs chat completion-rate trade (measure in D).
2. Honorarium vs member-standing incentive split per persona.
3. Instrument authorship loop: findings that reveal bad questions → instrument version bump; who signs instrument revisions (operator R vs A with veto window).
4. Whether shipper interviews wait for S2 or run early as Face design input (cheap now, colder calls).
