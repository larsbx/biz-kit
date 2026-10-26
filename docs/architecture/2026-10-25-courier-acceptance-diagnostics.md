# Courier acceptance diagnostics

Issue #125 remains the record for both historical intermittent assertions. Paired repairs are d-patch#30 and this repository's #126.

## Pinned baseline evidence

Client `4b8d6fcd8ebc8a4c53eef2aa03bb1cad14696a0a` was instrumented without changing its RetryAt or 401 expectations, producing `6abd92bd02b4a0ac3aff7f2207ebd93765f2c4b8`. Server production source was merge `38c7efc237943a5600d3a0e3083c97f8ecef5758`; workflow-only diagnostic commit was `18db5a45c4c2b5f30c9f1584001416bd8a6c00b3`.

[Run 40232736121](https://github.com/larsbx/biz-kit/actions/runs/40232736121) passed three fresh courier jobs, three driver jobs and browser acceptance. Neither historical assertion failure reproduced. The original unexpected SyncOutcome and the original logout delivery result remain unknown.

The courier traces consistently show restoration returning with no active network, followed by a ConnectException from the first online sync. Logout attempted an old pooled connection, recovered with a new connection, received 204, and the previous-token probe received 401. Missing transport readiness is demonstrated. Connection reuse as the cause of the historical failures is not demonstrated. No server revocation defect was found.

## Repair and evidence boundaries

The paired client now waits on Android network state plus actual HTTP readiness at both services through existing and fresh pools. Readiness checks do not submit status events or retry logout. Failure remains a failure; timeouts restore the network in finally and do not waive the assertions.

The hosted test uses an adb handshake with an independent, read-only aggregate database observer on the **isolated e2e stack**. It requires no server-side status effects while offline and exactly two effects after delivery and deliberate replay of the original signed events. Local queue states, signed chronological delivery, exact 401 after confirmed logout and ordinary driver sharing coverage remain asserted. Background WorkManager states and sanitized connection outcomes are retained for diagnosis.

Server instrumentation records only whether bearer/cookie sessions were presented and that synchronous durable deletion returned before the response. It emits no session, hash, principal or request contents. A regression checks 204 → 401, persistence across restart and continued validity of a separate session. This adds evidence, not a new revocation model.

The workflow pins the repaired client to an immutable SHA, prints both resolved revisions, keeps browser coverage, and runs three independent jobs per mobile role. Successful diagnostics as well as failures are printed; artifacts retain the sanitized trace on failure. The user can select a different explicit client ref for a manual run.

Local execution has no Android SDK/KVM and cannot download Gradle in this container. Hosted emulator results are recorded separately from local Python/shell checks. D-patch's unrelated central dependency-audit failure is not a courier result and is not waived here. Keep #125 open until the missing original failure causes are established or an explicit disposition is recorded.


## Proof-driven follow-up: late sign-in completion

D-patch#33 demonstrates a separate race: a delayed principal response could install
credentials after local sign-out. Its gated regression failed against the unchanged
client baseline before the fix. Fresh intent fencing now prevents admission after
sign-out or a newer persisted sign-in; discarded grants receive one explicit,
best-effort cleanup attempt. No failed delivery is called confirmed invalidation.

The client carries pinned Quint 0.25.1 / Apalache 0.47.2 checks and Lean 4.35.0
proofs with explicit abstraction limits in `spec/auth_intent/README.md`. The Lean
model proves stale-ticket exclusion across arbitrary finite intervening histories;
Quint requires an unfenced counterexample and bounds exhaustive exploration to six
transitions. These are abstract proofs with deterministic Kotlin conformance tests,
not a mechanically verified implementation or a retrospective cause for #125.

PR/push acceptance now pins client `187dcc2f08e42e5c8c684ef62fd954fb22829c92`
for three fresh courier jobs, three driver jobs and browser acceptance. Nightly
moving-main and explicit manual refs remain available. Server behavior is unchanged;
both resolved revisions are printed. Historical #125 remains open.


## Overlapping status synchronization follow-up

D-patch#34 records a deterministic client cache race relevant to manual/background
synchronization: a delayed response could overwrite newer server truth already
observed by another pass. The corrected gated baseline failed with ComparisonFailure
in [40281812181](https://github.com/larsbx/d-patch/actions/runs/40281812181);
the earlier virtual-clock timeout is excluded as causal evidence. Database-scoped
pass ownership now requires waiting callers to reread due rows after acquiring the
mutex, with cancellation and immutable retry tests and scoped Lean/Quint checks.

Pin repeated PR/push acceptance to client `abcca4c98c13725e809aa94bd418e633a8666700`.
Three independent jobs per mobile role retain zero offline effects, exactly two
effects after signed delivery plus replay, and previous-token 401 after confirmed
logout. Nightly moving-main and manual explicit refs remain available. This is a
reproducible client concurrency defect, not proof that the historical failures in
#125 exercised it; keep #125 open. Details and abstraction limits are in the client's
`spec/status_sync/README.md` and `docs/courier-acceptance-diagnostics.md`.
