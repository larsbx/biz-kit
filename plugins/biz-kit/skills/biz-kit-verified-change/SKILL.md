---
name: biz-kit-verified-change
description: Implement and review Biz-Kit repository changes with exact-head evidence, formal correspondence, and explicit merge-readiness reporting.
---

# Biz-Kit verified change

## Before editing

1. Inspect current `main`, open overlapping pull requests, architecture decisions,
   and the owning app's tests.
2. Identify source-of-truth, authority, persistence, replay, and compatibility
   invariants.
3. Distinguish implemented behavior from proposals and imported snapshots.

## Implement

- Make the smallest independently testable increment.
- Preserve canonical encoding, signature domains, idempotency, exact source binding,
  irreversible lineage, authorization revalidation, and refusal propagation where
  applicable.
- Prefer pure core rules plus explicit host/admission adapters.
- Add adversarial tests for stale revisions, substitutions, duplicates, authority
  changes, replay, and partial failure.
- Update Lean/Quint models only when correspondence to executable behavior is stated
  and checked; never present a pure model as proof of unmodeled Elixir behavior.

## Verify

Record:

- exact head SHA,
- targeted tests and counts,
- repository-wide checks that actually completed,
- formal compilation and axiom/declaration audits,
- hosted workflow run IDs,
- inherited versus introduced failures,
- untested production, deployment, migration, or human-review boundaries.

Open a pull request against `main`. Leave merge approval to the user unless the user
explicitly requests merging in the current task.
