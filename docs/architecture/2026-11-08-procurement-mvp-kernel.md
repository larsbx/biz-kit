# Procurement MVP: the first executable slice

Base: `65e9e34418decea3240ab500b731247a4135eb24`. Scope: an operator-assisted,
one-cooperative, one-category domestic B2B procurement pilot. This is the first
implementation PR, **not a deployed MVP, authenticated UI, or new ledger**.

## Implemented here

`CommerceCore.MerchantPilot.Workflow.apply_command/3` is a dependency-free
admission kernel inside the existing CommerceCore app. It represents request,
qualification, merchant-owned quote revisions, exact-revision buyer acceptance,
fulfillment, cancellation, dispute, and separate operator payment attestations.

Every newly accepted command advances the aggregate version once. The tuple
`{chapter, cooperative, request}` scopes the aggregate. An exact retry is inert;
reusing the id with different content is an error. Current authorization is
checked before retry handling. Revisions cannot change a quote's merchant.
Acceptance freezes the complete quoted snapshot and its source reference;
subsequent outcomes do not rewrite it. Expiry is checked against trusted time.
Unknown payments remain absent, not zero. An entered payment reference is
explicitly `operator_attestation` with `bank_verified: false`, never settlement.

The kernel trusts its aggregate input and the caller's authorization context.
It does NOT authenticate businesses, verify signatures, validate evidence
contents, or establish that a buyer actually consented. Those are integration
obligations, not guarantees created by the presence of an evidence-reference
string. No raw financial documents, contact information, or real pilot data
are included in these synthetic fixtures.

## Reproduce

From the repository root, with Python 3 and Elixir/OTP installed:

```sh
bash tests/procurement_mvp/check.sh
```

This does not fetch umbrella dependencies or start unrelated applications.
It compiles the actual new reducer with warnings as errors, runs 18 focused
ExUnit tests and one matrix test, and prints input digests. The Python oracle
enumerates 23 reachable abstract states and emits 828 cases spanning commands,
current/revoked authority, and current/stale versions. The Elixir matrix test
reconstructs each source state through the real reducer before comparison.
Four negative controls test the Python checker itself; they do not certify
that every possible implementation mutation is detected.

The reference quotient fixes one request and one quote ID, two quote revisions,
and whether any payment attestation exists; versions are tested relative to
the actual replayed prefix. Multiple quotes, text validation, expiry boundaries,
identity checks, retries, and money fields are outside this finite quotient;
some are covered by the focused tests, not by an exhaustive proof.

Lean 4.19.0 replay:

```sh
lean proofs/procurement_mvp/Workflow.lean
```

Five abstract theorems concern version increments, frozen accepted bindings,
unauthorized/stale admission, and acceptance not creating payment evidence.
Their printed axiom dependencies are retained. They are NOT a proof that
Elixir, the Log, a browser, or PostgreSQL refines the Lean model.

Quint 0.33.1 replay:

```sh
quint typecheck proofs/procurement_mvp/workflow.qnt
quint test proofs/procurement_mvp/workflow.qnt --seed=20261108
quint run proofs/procurement_mvp/workflow.qnt --invariant=invariant --max-steps=16 --max-samples=1000 --seed=20261108
```

Quint checks a smaller lifecycle abstraction. The final command is seeded,
bounded simulation, NOT exhaustive model checking or a liveness proof. There
is no automatic Lean-to-Quint or Lean-to-Elixir refinement bridge in this PR.

The dedicated workflow checks out the exact PR head, runs runtime, Lean, and
Quint independently, retains source-bound logs, and rejects failed, cancelled,
or skipped prerequisites. This is a **kernel gate**, not MVP release acceptance.
At authoring, only the Python explorer/negative controls, Python byte-compilation,
and shell syntax check were executed locally; Elixir/Lean/Quint require their
own successful receipts. Hosted results, not this paragraph, establish acceptance.

## Next implementation: signed admission, then three operator screens

The existing boundary is `CoopSubstrate.Log`; its gate is
`CoopSubstrate.Projections.Membership`, with type-dependent checks in
`CoopSubstrate.Protocol.Validity`. `RestaurantCore.Admission` and
`RestaurantHost.Orders` demonstrate the existing integration shape.

1. Register private procurement event schemas and connect check/fold to the
   same kernel inside the serialized Log gate. No second authoritative database
   and no unsigned save endpoint. A successful preflight outside the appender
   cannot authorize an eventual append. Verify current cooperative scope,
   business membership, allowed operation, operator key and revocation there.
2. Establish trusted admission time and replay semantics: current expiry is
   checked at admission, while recovery uses the admitted evidence, never the
   later wall clock. A browser-supplied timestamp is not trusted time. Bind the
   accepted snapshot, command id, actor and exact source references into the
   signed event. Test restart, concurrent competing writes and revoke-while-waiting.
3. Add authenticated requests, quotes/orders, and operations/results screens.
   Protect reads, POSTs and connected sessions; enforce CSRF and revocation.
   No buyer/merchant self-service accounts in this pilot. Do not expose a
   production write route while the signed adapter is missing.
4. Define the narrow procurement release, durable storage/backup/restore and
   exact-artifact hosted browser test. Only then call the workflow usable.
5. Export observed records to the existing merchant-pilot scorecard, retaining
   missing values. Review #333's fee/cost correction separately; don't claim
   transaction contribution proves that membership fees cover fixed overhead.

The next acceptance scenario is one signed request-to-fulfillment trace,
replayed after restart, plus conflicting acceptance/cancellation at one version
and revocation queued before append. A successful synthetic kernel test is not
that acceptance scenario.

Dispatch, international clearing, investment shares, extension marketplaces,
federation, mobile clients and broad writer migration remain outside this MVP.
No production deployment, infrastructure purchase, account change, or merge is
authorized or performed by this PR.
