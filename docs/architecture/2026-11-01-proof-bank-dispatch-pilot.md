# Proof Bank P0 Dispatch evidence pilot — model and implementation correspondence

Date: 2026-11-01. Status: **executable joint-check proposal, not accepted
implementation refinement or proof of production safety**.

This is stacked on [Proof Bank B0 #236](https://github.com/larsbx/biz-kit/pull/236)
and [first-party portfolio #241](https://github.com/larsbx/biz-kit/pull/241).

## Concrete bounded scope

Selected source: `apps/dispatch/lib/dispatch/operations/board.ex`.
Selected abstract theory: `formal/lean/BizKitDispatch.lean`.

The initial internal portfolio's broad Dispatch *operator exclusivity* target
is **not** proved by this Lean file. It stays unverified. This narrower
pilot concerns organization-scoped trip transitions, stale version refusal,
terminal state refusal and audit/version updates.

| ID | Lean theorem | Runtime witness (PostgreSQL integration) | Limitation |
| --- | --- | --- | --- |
| D-ORG | `foreign_organization_refused` | `BoardTest: a foreign organization's trip cannot be transitioned` | No complete equivalence proof for the actual organization/grant resolution |
| D-STALE | `stale_version_refused` | `BoardTest: a transition increments the version and rejects a stale retry` | SQL/CAS isolation and revalidation need independent review |
| D-TERMINAL | `terminal_states_refused` | `BoardConcurrencyTest: a queued transition rechecks the committed state` | Model atomic step != actual lock/transaction; tests are finite scenarios |
| D-AUDIT | `commit_appends_exactly_one_audit` | `BoardTest: a load is created, stopped, planned and run end to end` | The theorem models a list append, not a PostgreSQL commit |

Additional regression sources:
`formal/quint/dispatch_trip.qnt`,
`formal/quint/dispatch_idempotency.qnt`,
`dispatch_terminal_bug.qnt`, and
`dispatch_idempotency_bug.qnt`.
The [formal script](../../formal/quint/check.sh) checks type/safety/witnesses
and *requires* violations in deliberately broken models.

## Executable chain

`ProofBankCore.DispatchPilot.compile/0` compiles four distinct obligations
and references the named theorem and runtime test for each. Every output is
`unverified`, `needs_owner_review` and `inert`.

`ProofBankCore.DispatchPilot.audit_sources(root)` fails when known source
anchors disappear. It only checks textual existence, **not** that a theorem
typechecks or that a real assignment transition conforms to the model.

The dedicated workflow `proof-bank-dispatch-pilot.yml` runs two separate
lanes at the same **literal PR head SHA**, without trusting a merge-ref:

1. Check the model with the pinned Lean toolchain, fresh `leanchecker` and
   all-module axiom audit, plus the version-pinned Quint bounded checks and
   explicit negative controls.
2. Run the existing real PostgreSQL/PostGIS-backed `BoardTest` and
   `BoardConcurrencyTest` using the same database setup and pinned Mix
   dependencies as Dispatch's normal integration suite.

Both checks must pass on the **same exact source SHA** before reporting a
joint model-and-runtime-tested pilot. This only means that abstract proofs
and selected implementation scenarios succeeded independently; it is
**not** an end-to-end machine-checked refinement theorem for the Ecto/Ash
implementation, a complete security audit, or a production deployment.

## Acceptance still outstanding

- Domain owner approves the exact requirements and any source assumptions.
- Supply a reviewed mapping from each abstract transition and state field
  to the corresponding real DB/Elixir operation, including error cases,
  concurrency, authorization revocation and idempotent retry.
- Add adversarial mutation tests proving that weakening the implementation
  actually fails its regression witnesses; check source and test revisions.
- Verify explicit conformance under current and future source versions;
  mark evidence stale on any change to model, code, dependencies or schema.
- Complete outstanding production authorization and transport gates in
  Biz-kit; never accept the Proof Bank result as a signed business command.

No extension installation, financial authority or automatic app-generation
permission is provided by this pilot.
