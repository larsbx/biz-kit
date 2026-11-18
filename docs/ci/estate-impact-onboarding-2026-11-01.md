# CI impact inventory and Estate Governance onboarding (2026-11-01)

**Status: advisory inventory; not a replacement for existing CI.**
Source snapshot inspected: `main` at
`4c550f01effe1bedba235fa68899e1b435bdde02`.
Owner of the estate-wide standard:
[estate-governance DR-0005](https://github.com/larsbx/estate-governance/blob/main/docs/decisions/DR-0005-ci-impact-policy-ownership.md).
Tracking:
[estate-governance #21](https://github.com/larsbx/estate-governance/issues/21),
[biz-kit #245](https://github.com/larsbx/biz-kit/issues/245).

## Direct observations at that revision

- **34** GitHub Actions workflow files under `.github/workflows/`.
- **32** declare a `pull_request` trigger and **2** are manual-only.
- **27** declare path-filtered PR triggers, **5** unfiltered.
- **0** declare a `merge_group` trigger.
- Some workflows contain multi-platform matrix and database/PostGIS services;
  overlapping app and umbrella checks may repeat dependency acquisition and
  compilation.
- `ESTATE.toml` is **absent** from the inspected Biz-kit main branch, so the
  estate's v1 selector cannot currently validate Biz-kit as a registered
  estate member. Do not assert estate membership or a governance revision pin.

The counts are a source-code snapshot, **not** GitHub's required-status-check
configuration or proof of runner availability. The GitHub App could not read
protected branch rules in prior inspection. A filtered workflow must **never**
be substituted for a previously required check without explicit migration.

## Read-only coverage audit

`tools/ci_workflow_inventory.py` records the trigger configuration for
individual workflow files and reports unrecognized syntax as `unknown`. It
does not execute workflows, infer successful tests, or make authorization
decisions. `tools/test_ci_workflow_inventory.py` includes parser and refusal
cases. An optional, path-scoped `CI workflow inventory (advisory)` workflow
checks that the current local workflow inventory is recognized and retains a
JSON artifact. **This optional workflow must not be configured as a required
status check.**

Run locally:

```sh
python -m unittest tools/test_ci_workflow_inventory.py -v
python tools/ci_workflow_inventory.py --root . --require-complete \
  --output /tmp/biz-kit-ci-workflow-inventory.json
```

The inventory intentionally does not parse arbitrary YAML constructs:
unrecognized forms fail its `--require-complete` mode and require a reviewed
parser extension. The recorded `pr_path_patterns` are advisory; no claims
are made about whether these globs cover all transitive dependencies.

## Obligations that must survive optimization

| Change boundary | Required conservative coverage (proposed) |
| --- | --- |
| `mix.exs`, `mix.lock`, `config/**`, shared release source | Umbrella build, affected packages, integration contracts, portability; full fallback until validated dependency closure |
| `biz_kit_identity`, `biz_kit_cluster`, tenancy/authorization | Authentication, tenant isolation, cross-node/session revocation, portal and Dispatch callers |
| `coop_substrate`, signed ledger and admissions | Eventstore and replay acceptance, evidence provenance, dependent orchestration, consumer conformance |
| `task_core` | SchoolOps, orchestration, independent-package tests, portable consumer checks |
| ExtensionV1 and activation/contracts | Manifest validation, dependency-ordering, inert activation, SchoolOps/Dispatch adapters, negative tests |
| Dispatch and freight | Portable kernel plus PostGIS-backed integration, cross-repository API acceptance |
| `school_ops` | Curriculum and TaskCore integration, domain tests; not automatically the separate `school-ops` repository's complete browser acceptance |
| Documentation with executable links/fixtures | Relevant checks; do not assume documentation has no semantic consumers |
| Workflow, policy, test harness, unknown paths | Fail-closed full verification or blocked selection |

The table names **proposed obligations**, not evidence of passing tests.
Importing a root Mix umbrella dependency graph is insufficient by itself:
workflow, test fixture, generated contract, runtime and cross-repository edges
must be declared and independently checked.

## Migration sequence

1. Confirm whether Biz-kit should be a registered estate member and adopt an
   appropriate `ESTATE.toml` through a separate, reviewed governance decision,
   without inventing a canonical acceptance boundary.
2. Produce a versioned component/contract dependency graph from the actual
   `apps/*/mix.exs` sources and cross-app contracts. Detect cycles, unknown
   dependencies, unregistered test modules and unsupported source paths.
3. Adopt a pinned estate policy validator on an **advisory** PR path first.
   The shared executor must run the selector at a trusted revision and treat
   the proposal's policy data as untrusted. Preserve the existing application
   and research acceptance authority.
4. Demonstrate the selected coverage matches full-suite execution on
   representative positive, negative, security, concurrency and integration
   changes. Run periodic exhaustive checks to detect missed dependencies.
5. After exact-head PR and `merge_group` acceptance and branch-rule review,
   replace required check contexts in a separately reviewed migration. Keep
   old required contexts until replacement ones reliably report.
6. Measure median/p95 queue time, runner minutes, repeated compilation, red
   builds and false skips before optimizing expensive tiers.

## Hard blockers

- **Estate onboarding:** no `ESTATE.toml` in the source snapshot.
- **Branch protection:** status-check requirements have not been obtained.
- **Runner coverage:** GitHub Actions availability and capacity are separate
  from selection correctness.
- **Contract graph:** no independently accepted complete dependency map yet.

This PR intentionally leaves all 34 pre-existing workflows and their check
names unchanged. No application acceptance is weakened.
