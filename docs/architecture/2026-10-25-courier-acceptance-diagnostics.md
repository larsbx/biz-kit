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
