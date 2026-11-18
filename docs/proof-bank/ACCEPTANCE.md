# Proof Bank first-party acceptance

The Inventory and Dispatch pilots are on `main` through #255 and #292.
Their abstract Lean models, finite Quint checks and implementation tests are
separate evidence. Neither the static catalog nor a successful test run promotes
an application to proved, approved, activated or deployed.

## Source identity

The portable-core, first-party portfolio, characterization, pure-core probe and
Inventory workflows explicitly check out the literal pull-request head (or the
push commit). Each refuses a different checkout and records both the commit and
Git tree before checking it. Formal and Dispatch pilot workflows also explicitly
select the PR head. Compare the recorded revisions when combining their results;
a workflow's green badge alone does not establish the tested source.

Inventory changes trigger formal checking on both PRs and pushes to `main`.
Characterization auditing runs on application source/test changes so changed
evidence cannot silently retain an old pin until an unrelated catalog edit.

## Catalog maintenance

The catalog is an evolving registry of the platform and its umbrella applications; counts are generated from the current checked-out catalog rather than asserted in this document.
Registration and refreshed evidence hashes preserve the existing conservative
statuses. Under the recorded interim owner policy, refresh changed evidence with:

```sh
python3 scripts/proof_bank_characterization_audit.py --refresh
python3 scripts/proof_bank_characterization_audit.py
python3 -m unittest discover -s scripts/tests -p 'test_proof_bank_characterization_audit.py' -v
```

Refresh logs changed paths without asserting re-inspection. App drift, missing or
escaping evidence paths, and promoted statuses remain failures. Review and commit
the refresh before requesting acceptance; rerunning without changes is a no-op.

## Read-only per-application coverage report

The characterization CI now produces a per-application source evidence report
in its GitHub job summary, including exact source catalog identity, candidate
review state, observed test-file leads and remaining proof/runtime evidence
gaps. Reproduce locally:

```sh
python3 scripts/proof_bank_coverage_report.py --format markdown
python3 scripts/proof_bank_coverage_report.py --format json
python3 -m unittest discover -s scripts/tests -p 'test_proof_bank_coverage_report.py' -v
```

Generation fails closed when the underlying catalog inventory/evidence check
fails. The report does **not** execute tests or change statuses, and can never
turn a test-file lead into a proved application.

## Pilot evidence and remaining gates

- Inventory: [single-location pilot](characterizations/v1/INVENTORY_PILOT.md)
  and [per-location refinement boundary](inventory/REFINEMENT_V2.md), tracked in
  [#248](https://github.com/larsbx/biz-kit/issues/248).
- Dispatch: [state and authority correspondence](dispatch/REFINEMENT_V1.md).
  Global driver exclusivity is separately tracked in
  [#296](https://github.com/larsbx/biz-kit/issues/296).
- Research exchange: [executable verification core](research-exchange/README.md)
  for one prefunded reward slot and one compute reservation. Its isolated Lean,
  Quint and differential-test profile is separate from production server,
  database, identity and worker-runtime acceptance.
- Inventory and Dispatch Lean checking rebuilds inspected sources, replays with Lean's kernel and audits
  allowed axioms. Fresh replay uses the same kernel implementation; complete
  implementation refinement and an independently implemented checker are separate
  obligations.
- Generated extension candidates still need immutable approved specifications,
  independent conformance, artifact provenance and governed host lifecycle under
  [#238](https://github.com/larsbx/biz-kit/issues/238),
  [#239](https://github.com/larsbx/biz-kit/issues/239) and
  [#225](https://github.com/larsbx/biz-kit/issues/225).
- Optional Mojo/MAX construction needs actual device execution, CPU parity,
  reconstructed Lean-accepted proofs and end-to-end measurements before a
  performance claim. The accelerator has no proof-acceptance authority.

The next acceptance record must identify one literal source revision, the
successful formal and runtime jobs, negative controls, owner-reviewed assumptions
and unresolved refinement gaps. Historical or local results remain labeled with
their actual revisions and do not establish acceptance of a later change.
