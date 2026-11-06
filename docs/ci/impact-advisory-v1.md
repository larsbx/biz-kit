# CI impact automation: advisory V1 (2026-11-06)

**Authority:** read-only, advisory-only. **Tracking:** biz-kit #245, inventory #286 / PR #288; shared ownership: estate-governance #21.

This increment supplies a deterministic and automatically executed *impact proposal*, not a substitute for GitHub Actions checks. It does not edit existing path filters, change branch protection, run selected domain tests in place of existing jobs, or make an unverified "all-green" claim.

## Automated behavior

`.github/workflows/ci-impact-advisory.yml` runs without PR path filters on every pull request, merge-group event, push to main, nightly schedule, and manual invocation. It validates its Python refusal tests and creates a JSON receipt bound to the checked-out Git commit SHA and a versioned policy digest. An `always()` downstream receipt job fails if the planner did not succeed or its outputs are malformed. It deliberately does not claim anything about the results of other jobs.

For pull requests, the planner checks out the *actual PR head* and compares it against the exact recorded PR base commit using a three-dot Git diff. It reads NUL-delimited changed paths including both sides of renames and refuses missing or inconsistent revision evidence.

For merge queue, post-merge push, nightly and manual events the recommendation is unconditionally **full fallback**; no selective-skipping assumptions are made for those events.

If all PR changes are `lib/**/*.ex` or `test/**/*.exs` (including `.ex` support/test files) in the reviewed pure-app set, it reads `apps/*/mix.exs` and derives the transitive reverse-dependency closure from exact literal `in_umbrella: true` declarations. A declared workflow ownership mapping translates the resulting app set into *proposed* checks. If any transitive consumer lies outside the reviewed pure-app set (for example, Dispatch or the ledger), the plan falls back to full coverage. If the parser misses a dependency spelling, an app has no unique manifest, an unknown app or changed path is encountered, a workflow is missing, or a sensitive config/lock/authorization/Dispatch path changes, the proposal is **full fallback**.

This is a useful audit oracle, not a proof of dependency closure: test fixtures, generated contract files, runtime imports and cross-repository relationships do not all appear in the Mix dependency graph. No existing workflow is actually skipped because of this plan.

## Receipts

Artifact: `biz-kit-ci-impact-plan-<run-id>`, file `ci-impact-plan.json` (30-day retention). Contains:

- Exact candidate SHA, GitHub event, changed paths, policy SHA-256 and plan SHA-256.
- `focused_advisory` or `full_fallback`, including explicit reasons.
- Direct and transitively dependent umbrella apps, when safely derivable.
- Proposed focused workflows and the baseline unfiltered PR workflows that remain independent.

`full_fallback` is the **recommendation** to test all registered focused workflows; it is **not evidence** that those workflows ran or passed. Likewise, the final receipt's success means the impact planner ran correctly, not that domain acceptance passed.

## Reproduction

On any checkout of Biz-kit:

```sh
python -m unittest tools/test_ci_impact_selector.py -v
git rev-parse HEAD
python tools/ci_impact_selector.py --root . --event pull_request \
  --base <exact-PR-base-commit-SHA> --head <exact-PR-head-commit-SHA> \
  --output /tmp/ci-impact-plan.json
```

The checkout must be at the requested PR head and the base SHA must exist locally. `git fetch --no-tags origin <base SHA>` when necessary.

The tests include transitive dependents, rename detection, policy coverage, unknown paths, shared config/lock and Dispatch fallback, missing manifests, impossible statuses, and exact revision refusal.

## Acceptance before enforcement

1. Hosted PR run at the exact head must pass both advisory jobs, including unit tests, with the JSON artifact retained; an artifact alone is not sufficient.
2. Compare proposals with actual workflow invocations, and with repeated full acceptance on the **same commit**, over a reviewed positive/negative/change-type matrix. Report false skips (zero tolerance), test failures, duration, runner minutes, queue latency, and the uncovered dependency edges.
3. Get an authorized, complete inventory of required branch-check contexts and merge queue semantics. Read-only access to public repository rulesets does not prove the branch-protection status configuration.
4. Register an approved estate policy / `ESTATE.toml` if governance ownership approves it. Do not presume the shared selector is active.
5. Only after these gates may a *separate, reviewed PR* convert candidate selection into a gate and retire redundant workflows without losing required contexts. If a needed input is absent or malformed, use full test coverage rather than a silent skip.

### Explicit exclusions

No production changes, no branch protection changes, no automatic merge, no reduction of existing CI, and no claim of nightly **full-suite execution**. The nightly trigger currently re-evaluates the full **proposal** only; a genuine nightly full-suite orchestration with retained receipts remains an acceptance milestone.
