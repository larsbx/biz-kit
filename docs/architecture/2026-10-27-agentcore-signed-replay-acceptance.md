# Signed replay acceptance for staging AgentCore

This increment composes PRs #159 and #160 without installing a production
worker. The only business authority is the existing signed CoopSubstrate
ledger. `:pg` payloads are discarded; the worker reads committed replay and
uses the same current-grant/profile checks and PostgreSQL lease CAS as before.

`apps/coop_substrate/test/agent_event_acceptance_test.exs` adds six combined
regressions using actual `Log.append`, `Log.replay`, Log restart and the SAME
disposable PostgreSQL database for signed events and `agent_ops`:

- A forged signed run is refused; arbitrary notifications cannot create it.
  After authentic admission, duplicate notifications produce one launch.
- A committed run whose notification was lost is found by periodic replay
  after the Log restarts. The periodic timer is injected deterministically.
- Two independent PostgreSQL connections race delivery; one lease and one
  synthetic backend launch must result.
- A signed execution-grant revocation fences a running attempt and requests
  termination; repeated old notifications cannot reactivate it.
- A worker killed after a durable claim remains leased on restart when backend
  absence cannot be independently verified. Expiry does not grant a retry.
- A worker killed after backend creation but before handle attachment adopts
  the existing immutable backend via effect identity, without launching again.

The test backend and observation issuer are synthetic. They establish neither
real backend idempotency nor external receipt authenticity. The test deliberately
moves only the disposable lease expiry to exercise recovery without sleeping.
It does not alter the execution budget. Credentials and tokens remain host-only.

## Acceptance status

Local TaskCore: 104 tests passed. Operational nonintegration tests: 6 passed.
The new signed tests compile; the supporting CoopSubstrate application compiles
with warnings as errors. PostgreSQL end-to-end execution and hosted exact-head
Consolidation/volume checks remain mandatory before merge. A queued job is not
acceptance. The dedicated `AgentCore signed-ledger event acceptance` workflow
runs the combined cases and the existing signed-intent admission regressions.

Both original PRs needed formatting corrections; #160's negative linked-startup
test also needed to trap the expected EXIT signal. Those fixes were pushed to
the respective drafts, not hidden in this follow-up.

## Remaining release gates

Issue #92 remains open: authenticated deployment host, real distinct backend
conformance, durable backend deduplication and verified finality receipts,
secret confinement, scoped tool authority, candidate custody and controlled
rollback. No business write tools are enabled. The approved-profile and generic
ExecutionPort/RecoveryPort boundaries remain unchanged. The SQL and Compose
fixture remain compatible with Docker and Podman; this change does not claim
Podman runtime acceptance. Durable cursor discovery is a separate increment,
following the abstract Lean/Quint protocol in #162, and requires its own SQL
refinement/fault acceptance before activation.
