# Economic planning verification kernel

An inert, verification-first foundation for God's Eye View and the academic
economics planning program. The [accepted architecture and delivery order](../../docs/architecture/2026-11-11-economic-planning-verification.md)
covers multimodal transport, physical phenomena, fuel, markets, central banks,
geopolitics, commodities and precious metals.

This package admits exact evidence, proposes capacity allocations and costs,
and freezes analytical certificates using pure transitions. It does not fetch
data, run economic forecasts, reserve resources or execute business operations.

The next verification slice adds an [offline replay boundary](adapter/CONTRACT.md).
It accepts strict bounded JSON requests, obtains exact evidence from an immutable
host-provided snapshot, checks an injected scoped read-authority contract, and
replays from the empty initial state. A complete certificate is released only
after every proposed action succeeds and all requested reads are rechecked.
The host also pins each monetary source total to canonical cost components, so
caller-chosen names cannot bypass cross-quote deduplication. Python is used only
by this offline research reference implementation; no new application runtime
or service is introduced.

## Implemented verification surface

| Contract | Required behavior |
| --- | --- |
| Knowledge at issuance | Exact expected source revision and full signal key; current scope/read assertion; publication and receipt times no later than issue time. |
| Effective time | Future-effective announcements may be known now; quantities support allocations only in their applicable interval and the selected horizon. |
| Material and market identity | Preserve typed measure, material, grade, form, unit, currency, location, instrument and maturity; physical quantities cannot be interpreted as money. |
| Capacity | Optional quantity preserves unknown versus zero. A known, source-bound quantity limits aggregate allocation across all modes sharing a canonical resource/time bucket. |
| Cost coverage | Exact currency and source-linked total in canonical minor units; each total quote is single-use, with nonempty distinct component IDs disjoint from earlier costs. |
| Output classification | Derived certificates cannot be observations; synthetic or hypothetical evidence requires scenarios. Nowcast horizons contain issue time; forecast horizons start after it. |
| Immutable publication | Freeze manifest and admitted evidence/allocations/costs; future planning transitions preserve previous publications. |
| Authority | Preserve the operational-state token across accepted traces. No business writer or external execution capability is provided. |
| Replay boundary | Successful replay starts at `initial` and implies the proved accepted trace; a rejected prefix cannot be repaired by appending later actions. |
| Strict input | Reject duplicate or extra fields, forged authority/state, inconsistent catalogs, unsupported enums, lossy numeric forms and oversized input. Exact integers use decimal strings, with explicit null for unknown values. |

The source model is [lean/EconomicPlanning.lean](lean/EconomicPlanning.lean).
[lean/Proofs.lean](lean/Proofs.lean) proves properties of its accepted transitions
and traces. [lean/Contracts.lean](lean/Contracts.lean) supplies independent
expected theorem types. The theorem and scenario inventories are committed
alongside the sources. [quint/planning.qnt](quint/planning.qnt) is an independent
finite abstraction; its README records the domain, starting-state prelude and
guard-removal controls.

## Evidence classes and limits

- **Lean kernel proofs:** universal statements over the modeled arbitrary
  identifiers, quantities and accepted traces. Axiom dependencies are checked
  against the declared allowlist. A fresh replay of `Contracts` checks all its
  imported and defined constants, including the model, replay and proofs.
- **Executable Lean scenarios:** synthetic positive and negative cases exercise
  the actual transition functions, including successful publications.
- **Offline adapter evidence:** adversarial serialization/authority tests,
  independently specified golden cases, and full state/certificate comparison
  of the Python reducer with a JSONL oracle calling the actual Lean kernel.
  Deliberately broken implementations must be detected by the same comparator.
- **Quint/TLC:** complete exploration of the explicitly finite fixture plus
  deterministic scenarios. Each deliberately unsafe transition must produce a
  counterexample to its named invariant; an error or timeout is not success.
- **Harness controls:** incomplete/forbidden axiom evidence, false proofs,
  incomplete exploration and malformed counterexample results must be refused.
- **Source receipt:** exact Git revision/tree, package and shared-tool source
  hashes, pinned runtime distribution identities, commands and log digests.
  This is unsigned local/CI evidence, not a cryptographic attestation.

The host is responsible for authenticated identities and read grants, trustworthy
clocks, source truth/completeness, canonical resource and component identities,
the full resource-constraint set, and construction of a frozen source/catalog
context. Time buckets must use one host-normalized atomic partition. Public
tracking alone does not supply available cargo capacity.
Source/snapshot/model identifiers in the kernel are supplied bindings, not
computed content hashes or authenticated provider signatures. The verification
runner separately hashes the actual checked source and tool bytes.
The offline boundary computes separate domain-separated commitments to its
actual request, validated snapshot and prepared replay bundle. These are not
signatures. Host authentication, canonical identity construction and an atomic
provider/grant snapshot are still required for application integration. The
read callback is tested as a host contract; no identity provider is connected.

Capacity safety here is a bound on summed allocations per scalar constraint,
not full material-flow conservation or a network optimizer. Cost coverage checks
canonical supplied components, not whether two differently named reports mean
the same economic event. No probability calibration, empirical accuracy,
economic causality, Lean–Quint refinement, runtime refinement, physical-device
result or deployment is claimed by this gate.

The accepted-trace theorem starts at `initial` under one fixed `Context`.
`lean/Replay.lean` supplies that replay; its successful result is now connected
to the existing trace invariants by explicit theorems and independent contracts.
Raw pure functions do not authenticate a caller-supplied state. The Python
implementation has finite differential evidence, not a universal refinement
proof. Its public request surface accepts neither initial state nor certificates.

## Reproduce

The offline adapter entry point is `adapter.boundary.PlanningBoundary.plan`.
Construct its `FrozenSnapshot` and `HostIdentity` from trusted host values, and
supply the host's current read-authority callback. Only the request bytes are
caller-provided. The result is immutable serialized certificate bytes; exceptions
return no partial certificate. The complete synthetic fixture and hostile cases
are in [adapter/test_adversarial.py](adapter/test_adversarial.py).

Run the isolated boundary tests without a proof-tool installation:

```bash
python3 -B -m unittest proof_bank.economic_planning.adapter.test_adversarial
```

The complete gate below also compiles the oracle and checks both native replay
paths against it. The committed [adapter inventory](adapter/checks.json) fixes
every named test, golden case, seed, corpus size and mutation witness.

Use the existing checksum-pinned
[research-exchange toolchain](../research_exchange/toolchains.lock.json):
Lean 4.35.0, Quint 0.33.1, Apalache/TLC 0.62.4 and JRE 21.0.13. Python, Node and
the host environment remain trusted and their executable hashes are recorded.
Install outside the checkout:

```bash
python3 proof_bank/research_exchange/tools/bootstrap.py \
  --destination /tmp/economic-planning-tools
```

From a clean committed checkout, choose a new evidence directory outside it:

```bash
python3 -I proof_bank/economic_planning/tools/verify.py \
  --expected-head "$(git rev-parse HEAD)" \
  --toolchain /tmp/economic-planning-tools \
  --output /tmp/economic-planning-evidence
```

The runner refuses a mismatched head, dirty source, existing evidence directory,
missing test inventory, changed source during verification, unpinned tool bytes,
unapproved axioms, incomplete finite exploration or missing counterexamples.
Successful completion prints `ECONOMIC_PLANNING_VERIFICATION_PASSED`; the final
`receipt.json` retains separate claims and check results.

The [dedicated GitHub workflow](../../.github/workflows/economic-planning-verification.yml)
checks the PR head explicitly and retains its receipt and complete logs. It
does not claim that unrelated repository-wide workflows pass.
