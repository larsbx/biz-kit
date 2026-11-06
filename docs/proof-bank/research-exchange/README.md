# Research exchange verification core

The [standalone package](../../../proof_bank/research_exchange/README.md) supplies
the first proof layer for a proposed public research service exposing Lean,
mathlib, Quint and selected research libraries to contributing agents. It lives
under Proof Bank so its own Lake package and pinned toolchains remain isolated
from the existing application pilots.

This is a verification core and reference implementation. It does not register a
new umbrella application, deploy a public MCP/UTCP endpoint, authenticate remote
workers, meter physical compute, or issue service credit.

## Executable definitions and evidence classes

- The Lean kernels implement one prefunded reward slot and one independent
  compute reservation. Their 31 registered universal theorems cover binding,
  candidate immutability, stale/expired submissions, delayed verification,
  payout retries, local conservation, cancellation holds and terminal settlement.
- Twelve concrete Lean examples accompany the proofs. The strict axiom gate
  permits only `propext`, `Classical.choice` and `Quot.sound`. Exported theorem
  dependencies are replayed by both Lean's kernel and `lean4lean`.
- Quint checks two explicit finite state spaces, seven scenarios, and four
  deliberate faulty transitions. These establish finite safety evidence, with
  no fairness or liveness claim.
- The Python code is a reference oracle, test harness and verification tooling.
  It is not a production service implementation. Its comparison invokes the
  actual compiled Lean transition executable. Finite agreement is not a formal
  refinement theorem for Python, a database or the eventual server.

The package's [verification boundary](../../../proof_bank/research_exchange/docs/VERIFICATION_BOUNDARY.md)
and [model contract](../../../proof_bank/research_exchange/formal/lean/MODEL_CONTRACT.md)
remain authoritative about assumptions. In particular, trusted verifier and stop
inputs are premises; contributors must never supply them as authority in a
public API. Initial reward funding, multiple slots, global budgets, rejection and
reissue, revocation, persistent recovery and atomic database application remain
separate obligations.

## Repository acceptance

The [dedicated workflow](../../../.github/workflows/proof-bank-research-exchange.yml)
checks out the literal PR head or push commit, rejects a mismatched checkout,
records the Git commit and tree alongside the reviewed package digest, and runs
the complete ten-stage profile. It also records the executing workflow's ref and
SHA, which can differ from the checked-out package revision. A skipped
proof/model stage is not acceptance.
The upload includes the exported proof closure, axiom report, trace comparison,
counterexamples, logs, receipt and Git provenance. Failure receipts are retained
when produced. The optional local executable-location adapter is not used on
the standard hosted runner.

The workflow is scoped to this package, its integration documentation and its
own workflow file. Existing repository workflows retain their own triggers;
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
`tools/verify.py` with the reviewed source digest recorded in the workflow;
regenerating a manifest does not by itself authorize source changes. Toolchains
and generated evidence remain outside the committed source inventory.

The next service seam is a controlled verifier result followed by an atomic
`accept_candidate` domain transaction. Both MCP and UTCP adapters should invoke
that same operation, with exact challenge, artifact and environment bindings.
