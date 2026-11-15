# AgentCore and TaskCore execution-admission correspondence

Status: executable conformance cases and an abstract checked guard model.
This is not a universal implementation-refinement proof.

## Guarded behavior

An execution plan derives from signed run intent and current TaskCore
authority. Task source/version, operator and suggester grants, independent
read and execute grants, approved profile digest, capabilities and consent
must match. The Dispatcher performs this preparation before claim and again
after the durable CAS claim. Discovered authority changes request a durable
cancellation fence. A separate committed-lease check must succeed immediately
before invoking the adapter.

The intended obligations remain:

| Obligation | Meaning | Current evidence and boundary |
| --- | --- | --- |
| AT-1 | Launch requires the authorized run, task identity/version, independent grants and matching approved profile at the prelaunch observation, plus a valid claim | Abstract guard theorems; actual preflight/dispatch/SQL tests; signed fixture |
| AT-2 | A mutation observed after claim prevents launch and preserves a cancellation fence | Six two-adapter simulated-authority cases; three genuine-signed-history cases with fresh Log/SQL-session redelivery |
| AT-3 | Cancelled or superseded leases cannot submit candidate bytes | Existing lease/custody implementation and tests; not proved by `BizKitAgentTask` |
| AT-4 | Expiry or an ambiguous backend reply does not authorize retry without independently verified reconciliation | Dispatcher and SQL tests; synthetic backend crash/adoption cases; real backend proof remains open |
| AT-5 | A candidate never implies task completion, accepted evidence or a business effect | Existing candidate boundary; no general business-write tool is introduced |

`formal/lean/BizKitAgentTask.lean` contains the authorization model and a
separate `decideValidatedLaunch` guard. Its `blocked` outcome distinguishes
lease refusal from a persisted cancellation request. It proves no launch
without the observed guards, together with controls showing why omitting
either recheck permits an unsafe abstract decision. It is registered for
the pinned build, fresh kernel replay and all-module axiom audit.

The theorems do not model real signatures, SQL clocks, transaction commits,
network calls or crashes. They do not prove that an observed authority or
lease remains valid after the observation. Neither successful model checking
nor passing test cases establish a universal Elixir/PostgreSQL refinement.

## Evidence and next boundary

Keep three classes distinct: process-local authority simulation with real
PostgreSQL, genuine signed append/replay with synthetic backend observations,
and demonstrated persistence under a specified restart. Only the volume
workflow recreates the database container; only the signed fixture verifies
signed history and fresh replay. Neither establishes production power-loss
recovery or backend finality.

The next production proof boundary is the ordering among committed authority
changes, launch admission and external execution. A SQL lease check alone
cannot make these indivisible. Do not promote a general revocation-safe or
durable-execution proof badge from this increment.

Implementation paths, exact acceptance commands and remaining limitations
are documented in the [launch acceptance contract](../../architecture/2026-11-15-agentcore-launch-lease-acceptance.md).
