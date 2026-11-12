# Research exchange verification core and local adapter pilot

The [standalone package](../../../proof_bank/research_exchange/README.md) supplies
the first proof layer for a proposed public research service exposing Lean,
mathlib, Quint and selected research libraries to contributing agents. It lives
under Proof Bank so its own Lake package and pinned toolchains remain isolated
from the existing application pilots.

The original verification core and pure reference now have a local authenticated
HTTP/SQLite acceptance pilot beside them. It listens only on `127.0.0.1`, checks
fixed reviewed proof exports and moves disposable fixture credits. It does not
register a new umbrella app, deploy public MCP/UTCP endpoints, establish
production remote-agent identity, meter physical compute or issue service credit.

The [bounded MCP stdio adapter](../../../proof_bank/research_exchange_mcp/README.md)
lives beside this pilot. Its four-tool admission cycle has its own executable
suite and shares the reviewed core identity through `CORE_SNAPSHOT.json`.
The [integration acceptance contract](INTEGRATION_ACCEPTANCE.md) records the
PR #377 source/CI milestone. The opt-in [durable MCP bridge](DURABLE_MCP_BRIDGE.md)
now connects the same interface to SQLite and controlled dual replay of the
reviewed Lean export. Its separate representation proofs and runtime acceptance
must pass at the proposed revision; general research-source execution remains
outside that bounded profile.

## Executable definitions and evidence classes

- The Lean kernels implement one prefunded reward slot and one independent
  compute reservation. Their unchanged 31 registered universal properties cover binding,
  candidate immutability, stale/expired submissions, delayed verification,
  payout retries, local conservation, cancellation holds and terminal settlement.
- Twelve concrete Lean examples accompany the proofs. The strict axiom gate
  permits only `propext`, `Classical.choice` and `Quot.sound`. Exported theorem
  dependencies are replayed by both Lean's kernel and `lean4lean`.
- The Lean adapter acceptance and closure wrappers bring the total to **76 registered properties**.
  It invokes the existing `Reward.accept` and models current verifier identity,
  epoch, checked profile/candidate, row version and atomic matching settlement.
  Authenticated identity, checker truth and durable atomic publication remain
  premises. The required negative-control set grows from four to seven intended
  refusals. These counts require exact-revision audit and replay before acceptance.
- The original Quint models retain two finite spaces, seven scenarios and four
  faulty-transition controls. The adapter model adds 17 scenarios and 12
  targeted mutants; its current bounded graph has 676,952 reachable states.
  Acceptance requires complete exploration and genuine named-invariant
  counterexamples for the mutants. There is no fairness or liveness claim.
- The pure Python reference still compares actual compiled Lean transitions
  against finite traces. A separate local adapter adds authenticated HTTP,
  controlled checking and atomic SQLite writes. Finite agreement and HTTP/crash
  tests do not constitute formal refinement of Python, SQLite or a future
  production service.

The package's [verification boundary](../../../proof_bank/research_exchange/docs/VERIFICATION_BOUNDARY.md)
and [model contract](../../../proof_bank/research_exchange/formal/lean/MODEL_CONTRACT.md)
remain authoritative about assumptions. In particular, trusted verifier and stop
inputs are premises; contributors must never supply them as authority in a
public API. The pilot implements local credential separation, current enablement
and epoch fencing, permanent request binding and a transactional fixture-credit
operation. Initial reward funding, accounting across slots, global budgets,
arbitrary artifacts, production identity/financial integration and distributed
recovery remain separate obligations. A definitive exact-export mismatch closes the slot and refunds its original
escrow once. Unavailable and inconclusive checking leave the slot submitted.
A replacement requires a fresh explicitly funded slot.

## What the local pilot adds

The [pilot contract and reproduction guide](../../../proof_bank/research_exchange/adapter_pilot/README.md)
defines offline credential/profile provisioning and the loopback API. Workers
can lease, submit immutable bytes and read status. The exact configured verifier
principal has a separately authorized internal verify route that checks the
already stored candidate; requests cannot supply identity, `trusted`, verdict,
receipt, profile, checker command or payout destination as authority.

The approved artifact is the export of the reviewed trivial theorem
`forall n : Nat, n + 0 = n`. A different true arithmetic export is the wrong-target
control. Both pinned checker programs must actually replay the approved bytes.
This tests exact evidence binding and controlled verifier authority; it is not
arbitrary research validation or a sandbox for uploaded Lean source. Independent
replay runs different checker software on the same trusted local host.

The database transaction rechecks active credential role/scope, exact verifier
principal and epoch, frozen candidate/config/profile and row version after
checking. It persists reward state, one unique payout or refund and the canonical
request response together before replying. Effective credential changes advance
the epoch; a revoke/regrant cycle cannot revive a prepared result. SQLite uses
WAL, `synchronous=FULL`, foreign keys and `BEGIN IMMEDIATE`.

The adapter suite implements 27 mandatory checks covering real HTTP, credential substitution,
revocation/rotation, stale versions, changed-content request IDs, wrong-target
proofs, concurrent commits, and actual service-process death before/after commit.
Before commit, the terminal state, effect and request receipt all roll back.
After commit, they survive and retry returns the original result. The runner rejects missing or skipped tests. These are required gates;
the complete receipt for an exact revision establishes its observed results.

## Repository acceptance

The [dedicated workflow](../../../.github/workflows/proof-bank-research-exchange.yml)
checks out the literal PR head or push commit, rejects a mismatched checkout,
records the Git commit and tree alongside the reviewed package digest, and runs
every required stage in the current profile, including the adapter model and
local runtime acceptance lanes. It also records the executing workflow's ref and
SHA, which can differ from the checked-out package revision. A skipped
proof/model stage is not acceptance.
The upload includes the exported proof closure, axiom report, trace comparison,
counterexamples, fixed-export/checker evidence, local adapter acceptance records,
logs, receipt and Git provenance. Failure receipts are retained
when produced. The optional local executable-location adapter is not used on
the standard hosted runner.

Both exchange workflows are scoped to both packages, their integration
documentation and either workflow file. Existing repository workflows retain their own triggers;
the unfiltered Consolidation workflow still applies. The first-party application
characterization catalog is unchanged because this package is not a new app.

The original standalone v0.1.0 source was recovered from the reviewed archive:

| Identity | SHA-256 |
| --- | --- |
| Source archive | `71da52bc7269aa2584d966ad65baa117676338a22f7c0b859c9c9d232d79ad88` |
| Original package source manifest | `277540ebdc5b57133003b3ea45ccf607b5eac5c9402b991abac72fabf4fbcf81` |
| Original local verification receipt | `c1005a2449456af040b60e0059caf3a73971d9801778c8b2d8a96b30305366a3` |

That historical local run reported all ten stages passing, 1,532 declarations
accepted by both proof checkers, 1,898 differential traces and 3,856 matching
states, and complete finite searches of 99 reward and 21 reservation states.
Those observations identify the standalone source snapshot; they do not certify
a later Git commit. Repository acceptance is established by the workflow and
artifact bound to the exact revision being reviewed.

### Reproducibility correction in v0.1.1

A fresh installation found that the original Lean and JRE directory fingerprints
included temporary staging files absent from their release archives. Every
archive member and individually pinned checker/library matched. Version 0.1.1
replaces those two directory fingerprints with identities derived directly from
the SHA-verified archive members and confirmed on a clean installation:

| Distribution | Canonical tree SHA-256 | File/symlink entries | Regular-file bytes |
| --- | --- | ---: | ---: |
| Lean 4.35.0 | `de15da94c4dec7fed6dea9a2fa3373327a79caa558bb9cf8a51b19b2e7ecd014` | 17,938 | 3,137,937,793 |
| JRE 21.0.13+9 | `712d671b8a9d93cf7ee8690620ce6b014a77cfbc62e288e6f9dcc8ca2b7d4328` | 257 | 165,569,769 |

The archive pins, individual executable/library pins, Quint dependency tree,
transition definitions and proofs are unchanged. The runtime inventory still
includes every regular file and internal symlink and rejects extra files. The
source manifest is regenerated for this reviewed correction, and the workflow
pins its new digest. CI selects npm 11.9.0 explicitly because the observed local
npm version differs from the version bundled with Node 24.22.1.

## Reproduce locally

Enter `proof_bank/research_exchange` and follow its README. The installer pins
Lean 4.35.0, Quint 0.33.1, Apalache 0.62.4 and Java 21.0.13+9. Run
`tools/verify.py` with the reviewed source digest recorded in
`proof_bank/research_exchange_mcp/CORE_SNAPSHOT.json`;
regenerating a manifest does not by itself authorize source changes. Toolchains
and generated evidence remain outside the committed source inventory.

## Next production integration gate

Carry the demonstrated local boundary into a first-party host adapter using
existing CoopSubstrate/AgentCore authorization and approved execution profiles,
artifact custody and PostgreSQL operational persistence. `ProofBankCore` remains
an inert contract/blueprint core; do not add a competing signed business writer.
Hawala/TigerBeetle retains real financial authority. A local proof receipt or
SQLite credit movement cannot authorize an external payout.

Require exact candidate/profile and production-grant binding at admission, a
reviewed representation relation between production records and formal state,
concurrent/crash/recovery evidence under the actual storage profile, and a full
receipt for that exact integration revision. Preserve stable effect IDs and
provider reconciliation where financial effects cross transaction boundaries.
MCP and UTCP transports should then call the same accepted domain operation.

Compute execution, genuine stop observations, authorized physical usage
metering, global budgets and arbitrary-proof isolation each require a separately
stated and reproducible acceptance gate. The implemented fixed-export closure
does not classify arbitrary research artifacts.
