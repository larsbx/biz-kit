# Finite state verification

These models instantiate the reward and quota transition contract in
`../lean/MODEL_CONTRACT.md`. They are safety models of the verification layer;
they do not implement a public MCP/UTCP service.

## Scope

`reward.qnt` explores one prefunded unit, two competing principals (1 and 2),
clock values 0 through 2, at most two lease generations, and two artifact IDs.
Binding values comprise the expected `(target, input, environment, policy)` tuple
and one mismatch of each component. Requests include invalid principal 0,
invalid generations, expired deadlines, untrusted verification, and mismatched
evidence. All actions are atomic; every enabled ordering is explored.

The checked conjunction includes exact binding, matching owner/generation,
timely admission, immutable admitted candidate, retained slot after admission,
authorized artifact-bound payment, at most one payout, recipient agreement,
nonnegative balances, and conservation of the prefunded unit. Acceptance has no
current-time expiry guard: a timely admitted submission can be verified later.

`quota.qnt` explores one reservation with initial balance 3, cap and cost requests
0 through 4, and idle/reserved/running/cancelling/stopped/settled phases.
It checks balance conservation, nonnegative balances, empty settled holds, and
unchanged balances on every transition out of running/cancelling. Cancellation
requests cannot release a hold; a trusted stop acknowledgment must precede
settlement. Invalid operations and retries are no-ops.

Both models deliberately exclude multi-slot global accounting, unbounded clocks,
unbounded participants, fairness/liveness, database linearizability, authenticated
transport, cryptographic binding integrity, proof validation, sandbox isolation,
and correctness of compute metering. A trusted verifier decision and a trusted
stop acknowledgment are inputs, not facts established by these models. The Lean
kernel supplies separate proofs for arbitrary natural parameters. No formal
refinement proof connects these Quint models to the deployed service or database.

## Required checks

The runner uses Quint **0.33.1**, Apalache **0.62.4** for translation to TLA+, and
Java **21**. TLC is run to completion with a 1 GiB heap and two workers; it is not
a bounded-depth Apalache run. Its finite-state exploration uses TLC fingerprints,
whose collision estimate appears in the logs. The two positive checks require
the completion message and an empty search queue.

Seven deterministic scenarios cover normal settlement, cancellation and stop
ordering, quotas and retries, competing workers and delayed verification, stale
generations, exact binding/evidence, and the expiry boundary. The runner also
requires an invariant-violation trace from each deliberately broken transition:

| Mutant | Required violated invariant |
| --- | --- |
| Repeated payout after acceptance | `singlePayout` |
| Admission of a different target | `exactBinding` |
| Generation 1 submission after generation 2 lease | `freshAdmission` |
| Cancellation refunds a still-running reservation | `noEarlyRefund` |

Negative controls share the positive model but select a different next-state
action. The duplicate-payment mutant is capped at two payouts so its domain
remains finite. A negative control passes the harness only when TLC reports a
counterexample to the selected invariant; a compiler error, timeout, runtime
failure, or deadlock is not accepted as evidence.

## Reproduction

From the project root, with the pinned Quint package installed, a Java 21
executable, and `QUINT_HOME` pointing to the directory containing
`apalache-dist-0.62.4/apalache`:

```bash
python formal/quint/run_checks.py \
  --output-dir evidence/local/quint \
  --quint-cli /absolute/path/to/quint/dist/src/cli.js \
  --java-bin /absolute/path/to/java
```

All generated logs, translator output, and `summary.json` are written below the
output directory. TLC may also use temporary directories under the operating
system temporary directory. Source files are not modified. Only successful
completion of every required check prints `QUINT_CHECKS_PASSED` and returns zero.
The summary records model digests, exact commands, durations, positive search
statistics, and the invariant selected for each negative control.
