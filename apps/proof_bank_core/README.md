# ProofBankCore (scaffold, inert)

An umbrella-discovered, dependency-free, independently vendorable Elixir core
for the **Biz-kit Proof Bank** application foundry. It validates a structured
interview-to-requirement-to-obligation chain and returns a deterministic
blueprint with *unverified* proof obligations and *inert* activation status.

This deliberately does **not** implement an interviewer, model translator,
Lean theorem, production checker, extension loader, marketplace, governance,
database, network service or GPU engine. Structured requirements are not
automatically true, verified, approved or safe to execute.

## Run

Inside the Biz-kit umbrella:

```sh
cd apps/proof_bank_core
mix test
```

As an independent package, copy this directory outside the Biz-kit umbrella
and run `mix test`; no other Biz-kit app is required.

## API

`ProofBankCore.compile(candidate)` expects an **Elixir map with atom keys**:

```elixir
%{
  id: "dispatch-planner",
  revision: 1,
  title: "Dispatch planner",
  idea: "Suggest assignments for approval.",
  answers: [
    %{id: "A-1", question: "Overlapping trips?", answer: "Never."}
  ],
  requirements: [
    %{id: "R-1", statement: "No overlapping active trips.",
      kind: :invariant, answer_ids: ["A-1"]}
  ],
  obligations: [
    %{id: "O-1", claim: "No overlap for any active assignments.",
      method: :lean, requirement_ids: ["R-1"]}
  ],
  capabilities: ["dispatch.assignment.read"]
}
```

Input identifiers must be ASCII alphanumeric plus `-_.`, at most 80 bytes.
Supported requirement kinds are `:invariant`, `:behavior`, `:objective`.
Supported obligation methods are `:lean`, `:quint`, `:conformance`, `:manual`.
Every requirement must reference an interview answer and at least one
obligation. These checks establish **structural traceability only**.

The schema is an internal Elixir contract, **not** a canonical wire encoding.
Do not deserialize untrusted JSON into arbitrary atoms. A future adapter must
enforce an allowlisted schema and canonical encoding, with signed approvals,
tenant/project scoping, immutable revisions and evidence custody at the host.

## First-party Dispatch correspondence pilot (proposal)

The first applied Proof Bank review packet is
`ProofBankCore.DispatchPilot.compile/0`. It traces four named abstract Lean
trip-transition theorems to selected real Dispatch integration tests and a
**separate conformance-only** obligation for grant revocation under contention.
Neither textual test anchors nor passing isolated tests imply that the Elixir
implementation has been formally proved to refine the Lean model.

From the Biz-kit umbrella checkout:

```sh
cd apps/proof_bank_core
mix test --no-start
mix run --no-start -e 'IO.inspect(ProofBankCore.DispatchPilot.audit_sources("../.."))'
mix run --no-start -e 'IO.inspect(ProofBankCore.DispatchPilot.compile())'
```

The source audit checks **presence only**. The independent exact-head
Lean/Quint, PostgreSQL and portability lanes are in
`.github/workflows/proof-bank-dispatch-pilot.yml`. All emitted claims remain
unverified, all implementation refinement remains not established, and
extension activation remains inert. In particular, driver exclusivity is
**not** proved by the transition model.

See [the Dispatch refinement workpaper](../../docs/proof-bank/dispatch/REFINEMENT_V1.md)
and [internal-first acceptance issue #242](https://github.com/larsbx/biz-kit/issues/242).

## Engine boundaries

`ProofBankCore.ConstructionPort` returns **candidates**.
`ProofBankCore.CheckingPort` returns **checker claims with evidence refs**.
Neither port decides Biz-kit privileges, funds, governance outcomes, or
extension activation. Only independent profile-pinned verification and the
existing signed admission path can promote a real business decision.

See [rollout ADR](../../docs/architecture/2026-11-01-proof-bank-rollout.md).
