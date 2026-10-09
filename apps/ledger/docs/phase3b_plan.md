# Phase 3B — Harness.Ops: capture through the gate

> **Status: COMPLETE** (2026-07-11). Scope was the Harness.Ops brief's Phase 3B, its
> final phase; acceptance **[3B]** passes: the 2D end-to-end scenario runs ENTIRELY
> through the task modules (keys/genesis through build_started, seeds and hashes captured
> from shell output like a real handover), `status` names short legs in runbook terms
> and goes quiet when the gate is true, a mid-batch findings rejection stops there and
> names the entry with prior events standing, and the post-revocation flip re-blocks
> `build_started` with the gate's term verbatim. The runbook's `## Operating` section is
> now the primary path (iex appendix demoted to fallback). **The Harness.Ops brief is
> closed** — the repo's next event should be field exhaust. Gate honored: [3A] passed
> before this began.

## §0 Spine

```
every command = load role key → build → sign → append → print; rejections verbatim
status        = gate verdict + counts + SHORT LEGS NAMED in runbook terms —
                the cockpit line the founder checks between interviews
adopt         = the one deliberate act: hex hashes shown, typed confirmation
acceptance    = the 2D end-to-end reproduced through the TASK MODULES alone
```

## Settled decisions

- **Ops grows the capture/synthesis verbs**, tasks stay parse+prompt+print:
  `record_interview/4` · `record_finding/4` + `record_findings/1` (batch stops at the
  first rejection and names it — partial appends are fine, each finding is its own
  event) · `collect_document/3` (steward-keyed wrapper over `Harness.collect_document`) ·
  `corroborate/2` · `conflict/2` · `model_publish/0` + `model_show/0` ·
  `spec_publish/1` · `adopt/3` (governance) · `fixtures_publish/3` (dir → fixture maps,
  denylist file → lines) · `prospect/4` · `honorarium/2` · `checkpoint_emit/1` ·
  `build_started/1` · `status/1`.
- **`status/1` names the short legs** in runbook vocabulary ("interviews 3/5",
  "spec not adopted — runbook phase 5", "constants undeclared — runbook 0.3"). This is
  presentation over fold data, not a validity rule — the gate stays the only judge.
- **Findings batch input is a JSON file** (list of `{finding_id, interview_ref, kind,
  body}`) — reviewable before append, scriptable, no interactive loop to test.
- **Task names**: `mix harness.{interview,findings,document,corroborate,conflict,status,
  model,spec,adopt,fixtures,prospect,honorarium,checkpoint,build_started}` — the brief's
  `build-started` becomes `build_started` (Mix task naming), a trivial flagged deviation.
- **Hashes travel as hex** on the command line (`spec publish` prints the three; `adopt`
  consumes them); decoding is the task layer's only transformation.

## Build steps (TDD)

1. Plan doc (this file) — commit.
2. Ops capture/synthesis/status functions.
3. The fourteen tasks (thin).
4. `test/ops_pipeline_test.exs` — acceptance [3B]: the 2D scenario driven ENTIRELY
   through task modules under `Mix.Shell.Process`: keys/genesis → constants → instrument
   → consents (seed captured from the shell output like a real handover) → interviews →
   findings (batch file) → documents → corroborate → status (short legs named) → model →
   spec (hashes captured) → adopt (`--yes`) → fixtures (dir + denylist file) → prospect →
   status (gate true) → build_started → revoke (`--seed-file`) → status (gate false,
   legs named). Plus unit tests for the short-leg math.
5. Acceptance [3B] recorded; runbook gains the `## Operating` section (iex appendix
   demoted to fallback); status flip — commit; brief closed.

## Properties

```
P1  the whole runbook (0.2 → 7) is executable through mix tasks alone
P2  status is truthful: short legs match the gate's own arithmetic exactly (same fold,
    same constants) and vanish when the gate is true
P3  batch findings: one rejection stops the batch and names the offending entry;
    prior entries stand (each is its own signed event)
P4  adopt requires typed confirmation (or --yes) and the three hashes verbatim
P5  no new validity logic anywhere (removing any Ops check changes nothing — none exist)
```

## Adversarial

Findings file with one bad kind mid-batch (stops there, names it, earlier events stand) ·
adopt with hashes from a stale spec-publish (gate's `model_hash_mismatch`, verbatim) ·
fixtures dir containing an MC number (whole set unpublishable — 2D machinery) · status
consulted before constants (named short leg, not a crash) · prospect for a
synthesis-only consent (gate term verbatim).

**Gate out:** with [3B] green the Harness.Ops brief closes; the repo's next event should
be field exhaust.
