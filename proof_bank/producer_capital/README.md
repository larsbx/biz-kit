# Producer capital accounting kernel

This inert proof-bank package implements the verification slice of
[PR #329's ownership proposal](../../docs/architecture/2026-11-07-diminishing-producer-equity.md).
It has synthetic fixtures and pure state transitions. It has no runtime
integration, issuance, capital intake, payment, custody, title writer, or
deployment entry point. Merge review and independent legal, governance,
accounting, and Shariah decisions are separate gates.

## Recent runtime contract integration (2026-11-13)

The [new integration ADR](../../docs/architecture/2026-11-13-producer-capital-integration.md)
maps this proof package, the source-backed [Hanbali commercial contract taxonomy](../../docs/architecture/2026-11-13-hanbali-commercial-contract-taxonomy.md),
the existing `CapitalAccounts` *patronage/redemption* ledger, and the
`CoopSubstrate.ProducerCapitalPreview` **pure, non-authoritative** Elixir
preview. The Elixir slice checks USD 250 annual participation is HELD for
legal/NAV issuance, cap-table serial partition, revision- and value-bound
voluntary producer unit purchases, and no hidden principal guarantee.

**No machine-checked Lean/Quint-to-Elixir refinement is established.**
The Elixir helper does not implement grant authentication, trusted appraisal,
durable replay/source fences, cash settlement, ownership effect, earnings or
distributions. The existing proof bank still models these only under its
explicit trusted evidence/policy assumptions. Real money and title interfaces
remain disconnected. Do not interpret a passed Elixir preflight as satisfying
this README's atomic-transition proof acceptance.

## Model contract

| Area | Implemented rule |
| --- | --- |
| Project ownership | Each project has an immutable issued count and a list indexed by unit serial. Each serial belongs to the producer, the cooperative pool, or a named direct-investor business. An owner's exact fraction is its serial count divided by the issued count when the count is positive. Opening cap tables must be well formed. |
| Capital-account separation | Membership and optional cooperative investment have distinct balances and authority roles. A project pool position is an owner in that project's cap table. A project transition changes at most its named project. A cooperative discharge changes only its selected balance. Opening balances are abstract inputs. |
| Purchase | The buyer is the project producer. The exact nonempty, duplicate-free serial list must belong to the named nonproducer seller at commit. The project authority, producer and seller approve the exact request using live project-scoped grants. A successful purchase moves only those serials and advances the project revision. Every same-snapshot competitor must refresh, including a disjoint purchase. |
| Valuation and consideration | A trusted lookup supplies the quote from a live, independent project appraiser. The quote binds project, revision, currency, positive per-unit price and an inclusive validity window. The exact amount is price times unit count. An independent active observer must attest to the exact sale terms, including settlement kind and amount. The observer's input represents authenticated consideration and title evidence. |
| Profit and distribution | Signed, independently observed realized net profit increases retained earnings. A payout requires a positive allocation to distinct current holders, a current exact position attestation, contract allocation approval, explicit solvency clearance, and policy approval. The total is capped by retained earnings and liquid assets less modeled liabilities and reserves. Acceptance debits retained earnings and liquidity by the same amount. |
| Loss | An observed negative earning requires contract approval and a positive allocation to distinct current holders whose amounts sum to the exact loss. The model reduces retained earnings, permits a deficit, and journals the allocation without creating a cash debit or investor payment obligation. Future realized earnings first reduce a retained deficit in this model. |
| Replay and revocation | A transaction ID is single-use across actions. A canonical economic source ID is single-use across projects and both cooperative classes. Its first accepted effect is immutable, even across a changed transaction ID or a new effect type. Authorized grant revocation is permanent for that grant ID. A later grant uses a new identity. |

Amounts are exact natural numbers in an abstract smallest denomination, with
signed integers for realized earnings. The valuation kernel checks integral
per-unit prices. Appraisal methods, fractional quotes, rounding, currency
conversion, identity admission, liability ranking, member NAV and redemptions
remain outside this slice. The project position starts from a trusted
snapshot. Distributions reduce its liquid balance, while recognition of
earnings alone does not change cash. Position refresh, liquidation, issuance,
capital calls, and other ownership transfer types are outside the transition
set. A policy profile must determine whether the modeled rules fit an
actual agreement.

### Trust and implementation boundary

- `Context` supplies a nondecreasing trusted time, canonical grant identity and
  principal, exact request signatures, appraisals, observations, and policy
  outcomes. The kernel checks their scope, binding, freshness, independence
  and revocation as specified. Authentication, clock integrity, canonical
  receipt identity across evidence providers, and the truth and sufficiency
  of consideration, title and financial evidence are outside the proof.
- `allow`, `allocationAllowed` and `distributionSolvent` are required inputs.
  They stand for unresolved eligibility, admissible appraisal and settlement
  methods, legal and governance authorization, signed allocation terms, and
  independent solvency clearance. The package supplies no default policy.
  Synthetic fixtures use explicit test values. Tests reject a payout with
  ample liquid assets when the independent solvency input denies it.
- Lean proofs apply to accepted atomic transitions from the declared opening
  state. A database refinement must establish trusted snapshot loading,
  commit-time grant and revision checks, crash-safe serializable updates,
  idempotency, durable receipt indexing and economic source deduplication.
  The model alone cannot make external settlement and accounting atomic or
  decide whether two evidence providers described the same real event.
- The scope of “lawful” here is conditional admission under supplied policy
  and evidence. The proof provides no regulatory or Shariah approval.

## Evidence classes

- **Lean kernel acceptance** covers arbitrary project IDs, valid opening
  tables, unit counts and accepted traces. See `lean/Proofs.lean` for
  partition and conservation, exact transfer and stale snapshots, producer
  title persistence, journal immutability, cross-account replay, live
  authorization and revocation, account isolation, distribution guards and
  debits, and exact loss allocation. The runner reports each theorem's
  axiom dependencies.
- **Executable regressions** run the Lean transition function on synthetic
  requests. They include both commit orders, refreshed overlap, wrong
  title, mismatched receipts, self-attestation, revoked signatures, replay,
  loss allocation, liquid-asset exhaustion and denied solvency.
- **Finite Quint evidence** independently represents one mutable project,
  four serials, three owners, two cooperative classes, two clock values,
  finite request IDs and amounts, fixture approvals, and atomic
  interleavings. It explores that finite graph to queue exhaustion via TLC.
  It includes seven scripted scenarios and twelve guard-removal controls,
  each of which must violate its named invariant with a counterexample.
  Quint abstracts rich grants, sources, valuation and positions to fixture
  data and monitors. The two models have no machine-checked refinement
  relation.
- **Implementation assumptions** include the external evidence and policy
  boundary above. These remain separate from the verification receipts.

## Reproduction

From the repository root, obtain the same pinned Linux x86-64 Lean, Quint,
Java and Apalache toolchain used by the
[research-exchange proof bank](../research_exchange/README.md#reproduce-the-complete-profile).
Its `tools/bootstrap.py --help` documents installation. Use an empty output
path outside the checkout.

```bash
python3 proof_bank/producer_capital/verify.py \
  --lean /path/to/lean-4.35.0-linux/bin/lean \
  --quint-cli /path/to/node_modules/@informalsystems/quint/dist/src/cli.js \
  --quint-home /path/to/quint-home \
  --java /path/to/jdk-21/bin/java \
  --output /tmp/producer-capital-receipt
```

On the affected Linux PID-namespace environment, pass
`--app-path-adapter /path/to/toolchain_app_path.so` from that same bootstrap.
The runner checks the tool digests it consumes against the shared lock and
records the source commit, tree, source digests, commands and separate logs.
A timeout, compiler failure or deadlock cannot satisfy a negative control.
