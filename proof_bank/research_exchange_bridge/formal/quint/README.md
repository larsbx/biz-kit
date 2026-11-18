# Independent finite durable-bridge model

`bridge.qnt` specifies the transaction boundary independently of the runtime.
It neither imports nor generates the runtime or frozen core model. Its successful
check establishes safety of this finite transition system. It is not a refinement
theorem about the Python, SQLite, Elixir, MCP, or subprocess implementation.

## What the states represent

There is one immutable admitted submission, its queued job and outbox, two
prepared workers, owner principal 1, foreign principal 2, and internal verifier 3.
Submission, job, and pending outbox appear in one atomic admission action.
A prepared result contains the full abstract binding, both grant epochs, the
durable version, current profile, verifier identity, and a checker verdict.
Preparation and commit are separate actions, so every intervening environment
action can invalidate the snapshot. Verdicts are accepted, rejected, or
inconclusive; the model does not establish the truth of checker verdicts.

The `source` equality representative stands for the complete source identity
(library, revision, snapshot, and core). Owner, target, artifact, environment, and
policy have separate equality representatives. Worker 1 may provide an exact
record or substitute any one of these fields, the verifier, or the profile;
worker 2 provides an exact record. Both independently choose any verdict. This
does not cover arbitrary simultaneous substitutions, arbitrary identities, or
multiple jobs. Runtime tests must exercise each concrete binding field and
canonical request identity, including changed payloads reusing an identifier.

Both terminal decisions atomically update the formal disposition, terminal
receipt, delivered outbox, and one effect counter. A crash before that action
loses the in-memory preparation and leaves durable state pending. A crash after
it preserves the winner and an authorized retry returns its durable receipt.
These atomic specification actions are assumptions to be checked against actual
database transactions; the model has no partially executed SQL instructions.
Multiple workers may perform checking; only one terminal transition may win.
The effect counter does not assert exactly-once physical checker execution.

Inconclusive checking pauses the outbox and leaves the represented formal state,
including its row version, unchanged. It consumes only that completed checking
attempt's own slot; competing prepared results remain available. One trusted
operator retry is in scope. It returns the outbox to pending without changing
formal row version or clearing other in-flight tickets. A still-current definitive
ticket may commit once from either a pending or paused outbox. A genuinely stale
version, grant epoch, binding, or profile remains inadmissible. The public
retry/read operations require the owner and a current
enabled requester grant; they only retrieve the durable result. Operator retry
is a trusted environment action, not a modeled unauthenticated public endpoint.

## Finite bounds and exploration

Each requester and verifier grant may be revoked once and regranted once,
with epochs 0, 1, and 2. The profile may rotate once. There is one independent
version-only interference and one operator retry. Formal row versions range from
0 through 2. A second inconclusive attempt can remain paused. Crashes and
restarts may recur, but their represented state remains finite.

The runner uses TLC's reachable-state exploration without a fixed search-depth
limit. A positive result requires the completion message, a complete-graph depth,
and **zero states left on the queue**. A timeout or incomplete exploration fails.
The evidence summary records actual counts and the full source/runtime hashes;
counts are not hardcoded acceptance thresholds. There is no liveness or fairness
claim and no theorem for unbounded jobs, epochs, retries, identities, or versions.

## Checked properties and adversarial controls

Each row identifies the actual invariant passed to TLC for its failing control.
The controls alter a transition or omit a guard. They must produce a trace
violating that specific invariant; merely failing to execute does not count.

| Property | Mutant step(s) |
| --- | --- |
| Atomic submission/job/outbox admission | `splitAdmissionStep` |
| Immutable admitted submission and job binding | `replacedSubmissionStep` |
| Exact terminal evidence binding | `sourceStep`, `targetStep`, `artifactStep`, `environmentStep`, `policyStep`, `ownerStep` |
| Current enabled requester and its prepared epoch | `requesterGrantStep`, `requesterEpochStep` |
| Internal verifier, current enabled grant and prepared epoch | `verifierAuthorityStep`, `verifierGrantStep`, `verifierEpochStep` |
| Current durable version | `versionStep` |
| Current profile | `wrongProfileStep` |
| Atomic disposition/receipt/effect/outbox publication | `publicationStep` |
| At most one terminal effect | `duplicateStep` |
| First terminal winner cannot change | `overwriteStep` |
| Only definitive checking permits terminal commit | `inconclusiveStep` |
| Refused commit preserves durable state | `sourceStep` checked separately against `refusalsInert` |
| Inconclusive pause preserves formal state and row version | `inconclusiveEffectStep`, `inconclusiveVersionStep` |
| Operator retry preserves formal state and row version | `retryEffectStep` |
| Crash preserves durable state | `lostOutboxStep` |
| Owner-scoped reads and retries | `unauthorizedReadStep`, `unauthorizedRetryStep` |
| Retry returns the durable terminal receipt | `wrongReplyStep` |
| Declared version bound is preserved | `unboundedVersionStep` |

The runner performs 28 named mutant checks across 27 distinct mutated transition
relations. The source-substitution mutant is checked against both exact evidence
and refusal inertness. Twenty-one deterministic scenarios give readable examples
of success, rejection, competing winners, stale fences, inconclusive pause/retry,
before/after-commit crash, unauthorized reads, and current or truly stale tickets
returning after operator retry. The exhaustive run checks the
conjunction of all properties across all reachable states, beyond these examples.

## Invocation

Use the existing frozen core toolchain distribution, without changing its lock:

```sh
python3 -B proof_bank/research_exchange_bridge/tools/run_model_checks.py \
  --quint-cli /path/to/quint/node_modules/@informalsystems/quint/dist/src/cli.js \
  --java-bin /path/to/jdk-21.0.13+9-jre/bin/java \
  --quint-home /path/to/quint-home \
  --output-dir /path/to/new-empty-evidence-directory
```

`QUINT_HOME` may supply the home instead of `--quint-home`. The per-process timeout
defaults to 300 seconds and may be set explicitly with `--timeout-seconds`.
The output directory must be new or empty. The runner emits `summary.json`, a
separate command log per check, and the generated model-checker work files.
It checks Quint 0.33.1, Apalache 0.62.4/TLC, JRE 21.0.13+9, executable/jar hashes,
and complete Quint dependency/JRE tree hashes against the frozen core lock.
Node and Python executable hashes are recorded as trusted environment inputs.
All source and runtime identities must still match when the run finishes.
