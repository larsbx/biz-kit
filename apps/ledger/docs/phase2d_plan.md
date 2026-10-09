# Phase 2D — Fixtures (anonymization predicate) + funnel emission

> **Status: COMPLETE** (2026-07-11). Scope was the Harness-D brief's Phase 2D, its final
> phase; acceptance **[2D]** passes: a fixture set with any predicate violation is
> unpublishable (nothing persists); every funnel record resolves to its interviewee,
> interview, and consent class, with post-revocation emission unrepresentable; and the
> full real-machinery pipeline (Synthesis → adoption → Fixtures → funnel) drives gate(D)
> true on synthetic data, lands BuildStarted, and flips false under revocation of a
> load-bearing source. **The Harness-D brief's machinery is complete** — results in
> `HARNESS.md` (normative); gate(D)'s real evaluation is the founder's field work.
> Gate honored: [2C] passed before this began.

## §0 Spine

```
fixture set   publishes ⇐ every fixture passes the anonymization predicate — a build
              failure, not a review note (11 P2); the operator's denylist is an INPUT,
              never part of the artifact (it contains the sensitive strings)
predicate     = regex classes (MC/DOT, email, phone) + literal denylist; non-text
              content fails closed as unscannable — v0 is text-only, flagged
prospect      = FunnelProspectEmitted{prospect_ref, interviewee_ref, interview_ref, track}
              ⇐ consent class prospect_record, active — the lead knows why we're calling
              (11 P7, 12 P6); post-revocation emission unrepresentable
end-to-end    the full pipeline on synthetic data — real Synthesis/Fixtures modules, not
              random hashes — drives gate(D) true, BuildStarted lands, revocation flips it
```

## Settled decisions

- **`Harness.Anonymization`** — the predicate is mechanical where it can be, explicit
  where it can't: regex classes for MC/DOT numbers, emails, phone numbers; a per-set
  **denylist** of literal strings (names, companies, lanes) supplied by the operator,
  because name detection is judgment. Case-insensitive throughout. Non-UTF-8 content is
  `:unscannable` and **fails closed** — v0 fixtures are text (parser fixtures are
  extractions); scanning binaries convincingly is future work, FLAGGED. Document quirks
  remain the standing adversarial case (11 §5).
- **`Harness.Fixtures.publish/7`** — validates every fixture against the predicate
  (any violation aborts the whole set: *fixture sets fail build*), bundles
  `FixtureSetV1` (name-sorted, deterministic), stores it content-addressed, and appends
  the 2A-gated `FixtureSetPublished` (source consent classes checked at the gate).
- **`FunnelProspectEmitted`** — the emission seam only (outreach sequencing is the 12
  engine's brief): unique `prospect_ref`; the named interview must exist and belong to
  the named interviewee; consent must be active **and** include `prospect_record`;
  `track ∈ D/L/Y` (the 12 tracks; S2 shippers deferred with 11 §6.4). Bilateral-classed.
  Consumers must re-check consent before contact — the gate blocks new emissions
  post-revocation, but already-emitted prospects going stale is the consumer's check
  (12 P2 is cross-channel and downstream), FLAGGED as the seam contract.
- **The [2D] end-to-end test uses the real machinery**: the 2A end-to-end run proved the
  gate over hand-built events with random hashes; 2D adds the full pipeline — consents →
  interviews → findings → documents → corroboration → `Synthesis.publish_model` →
  `publish_spec` → governance adoption with the real `model_hash` → `Fixtures.publish` →
  funnel emissions → `gate(D)` true → `BuildStarted` → revocation flips it all.

## Build steps (TDD)

1. Plan doc (this file) — commit.
2. `Harness.Anonymization` (violations/anonymized?; regex classes + denylist; fail-closed
   unscannable) with unit tests.
3. `FunnelProspectEmitted` type + gate checks + fold uniqueness state.
4. `Harness.Fixtures.publish` (predicate-enforced bundle → artifact → gated event).
5. The full-pipeline end-to-end test (acceptance [2D]).
6. Acceptance recorded; status flip; Harness-D brief closed (machinery side) — commit.

## Properties

```
P1  a fixture set containing any predicate violation is unpublishable — no artifact, no
    event, nothing persists
P2  the denylist never appears in any artifact or event
P3  every funnel record resolves to (interviewee, interview, consent incl.
    prospect_record); emission after revocation is unrepresentable
P4  the pipeline end-to-end: gate(D) true on synthetic data via the real modules;
    BuildStarted lands; revoking a load-bearing source flips gate(D) false and
    re-blocks BuildStarted
P5  fixture bundles are deterministic (name-sorted) and content-addressed
```

## Adversarial

MC number with unusual spacing/prefix (regex classes tested against variants) · sensitive
name smuggled past regexes (the denylist is the answer; its omission is operator error —
judgment, not mechanics, FLAGGED) · denylist leaked via the artifact (P2: input-only) ·
prospect emitted for a synthesis-only consent · emission racing a revocation in one batch
(batch-order visibility: event N sees N−1) · binary fixture slipping past the scanner
(fail-closed unscannable).

**Gate out:** with [2D] green the Harness-D brief's machinery is complete. `gate(D)`'s
real evaluation is the founder's field work; the D build brief is cut only when it is
true on real, consented data.
