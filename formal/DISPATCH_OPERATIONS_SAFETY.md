# Dispatch operations: proof-first acceptance packet

Status: **proof obligations specified, hosted verification pending**.
Companion runtime remediation: [PR #205](https://github.com/larsbx/biz-kit/pull/205),
fixing the already-merged [PR #202](https://github.com/larsbx/biz-kit/pull/202).

This packet is deliberately narrower than a proof of Elixir/Ash, PostgreSQL,
SvelteKit, the SSH stack, or the OAuth session implementation. It fixes the
mathematical transition and request-identity contracts **before accepting**
the runtime refinement. Both the positive checks and deliberately unsafe
negative controls must execute successfully at the same immutable PR head.

## 1. Abstract state and invariants

Lean `formal/lean/BizKitDispatch.lean` specifies a one-trip transition:
`PLANNED -> ACTIVE/CANCELLED` and `ACTIVE -> COMPLETED/CANCELLED`.
No action is admitted from `COMPLETED` or `CANCELLED`. Every admitted move
requires actor-organization equality and, when supplied, a matching version.
A successful commit increments the version once, appends exactly one audit
event and retains organization ownership; refusal leaves the abstract state
unchanged. `endPresent` abstracts `ends_at != nil`, including a scheduled end
on a PLANNED or ACTIVE trip. Activation preserves its incoming timestamp;
complete/cancel overwrites it with the actual end time. `terminalWritten` is a
separate ghost history bit: a complete/cancel commit has occurred. It is never
inferred from timestamp presence. Both Lean and Quint preserve both fields on
activation and set both on complete/cancel. Exact timestamp values are a runtime
refinement obligation; the models only track presence and terminal history.

The same Lean module binds a replay claim to
`(tenant, role, key, method, resource, canonical-body-digest)`.
Changing any of the first five identity fields (including method and resource)
cannot satisfy exact claim equality. The digest collision assumption and the
durable atomic idempotency claim are **not** proved.

Quint `dispatch_trip.qnt` explores valid lifecycle moves, rejected attempts
and restarts. Initialization covers trips with and without a scheduled end.
Its safety property requires terminal history to remain terminal, activation
to preserve the scheduled timestamp's presence, and one audit per version
increase. Reachability checks require ACTIVE trips both with and without a
scheduled timestamp, as well as completed/cancelled trips and rejected attempts.

Quint `dispatch_idempotency.qnt` covers **one unexpired claim/retention epoch**
for one tenant/role/key. A matching retry cannot perform a second mutation
**within that epoch**. The epoch starts with a committed claim and ends at its
expiration (24 hours in the runtime). Expiration/purge and acquisition of a new
claim are outside this model; its mutation count is epoch-local. Restart means
a process restart while the same durable claim is still live. Replay and
conflict must both be reachable.

The Lean replay equality predicate likewise compares identity candidates for
one live claim; it does not establish expiry selection or global exactly-once
execution. After expiration, the runtime may intentionally execute the same
request again in a new epoch. `IdempotencyTest` checks expiration without a
sweep, permits that second mutation, and verifies a subsequent live retry
replays the second response without a third mutation.

**Negative controls are essential:** `dispatch_terminal_bug.qnt` allows
resurrection after a recorded terminal commit, and `dispatch_idempotency_bug.qnt`
allows a body-only key to replay a different resource. Both must typecheck
and yield concrete invariant violations, not merely tool errors.

## 2. Refinement obligations to existing code

| Property | Model | Runtime site | Concrete acceptance |
| --- | --- | --- | --- |
| Source-status guard after lock | Lean `terminal_states_refused`; Quint `dispatch_trip` | `Dispatch.Operations.Board.transition/4` | All 12 source/action cases; separate-session lock contention, with and without `expected_version` |
| Scheduled end preservation | Lean `activation_preserves_scheduled_end`; Quint scheduled/unscheduled ACTIVE witnesses | `Board.plan/3` and `Assignment.activate` | Non-null planned `ends_at` survives activation; complete/cancel replaces it; forbidden reactivation preserves terminal timestamp/version/audit |
| No stale overwrite | Lean `stale_version_refused` | `Assignment` update actions with `optimistic_lock(:version)` | Stale expected version; stale Ash snapshot |
| Organization isolation | Lean `foreign_organization_refused` | `Board.own_trip/2` before and after row lock | Foreign trip remains 404 and unchanged |
| Audit-event atomicity | Lean `commit_appends_exactly_one_audit`; Quint `auditCount == version` | `Board.transaction`, `audited` | One exact event per accepted move, zero for refused moves, rollback on persistence failure |
| Resource-bound replay | Lean `target_change_cannot_replay` and `method_change_cannot_replay`; Quint `dispatch_idempotency` | `OperationsController.write/3` + `Idempotency.execute/4` | Same-key retry same target and body; cross-target/method/body = 409; zero second mutation within one unexpired claim epoch |
| Claim retention boundary | One-epoch assumption, not a global exactly-once theorem | `Idempotency.resolve/7` and `purge_expired/1` | Expired claim permits a new mutation; a live retry then replays the new epoch response |
| Hostless Dispatch | UI composition requirement, not Lean theorem | `PanelContent.svelte` and `panels.ts` | Render Dispatch sign-in without SSH hosts on Windows/macOS/Linux |
| Authentication isolation | Existing auth contract (not modeled here) | `desktop/src-tauri/src/dispatch.rs` | Preserve PKCE, `/v1/` restriction, session isolation, no redirect following |

### Trust boundary

The abstract model assumes the permitted transition and idempotency identity
are the guards executed at the database serialization point. It does not establish
that all possible Ash updates, bulk imports or alternate write endpoints use
those guards. It also does not establish the persistence order, completeness,
cryptographic collision resistance or authorization of external HTTP paths.

Actual proof-to-code correspondence therefore requires the hosted Dispatch
PostgreSQL/PostGIS integration lane, desktop SvelteKit tests and Rust tests,
and existing portal/integration checks to pass **on the same current head**.
Queued, cancelled or skipped jobs are not passing evidence.

The current idempotency format intentionally fails closed for body-only legacy
claims until their retention expires. This avoids replaying an ambiguous
previous response for a different mutation target.

## 3. Reproducible verification

Run with the project's pinned Lean installation:
```sh
bash formal/lean/check.sh
```

Run with pinned Quint and Apalache:
```sh
bash formal/quint/check.sh
```

The proof workflow performs a fresh Lean kernel replay and per-module axiom
audit including `BizKitDispatch`, bounded Quint safety checks, nonvacuity
witnesses and both Dispatch negative controls. Changes to the Dispatch
transition controller, idempotency code or host-requirement panel trigger
this workflow.

In CI also require:
```sh
(cd apps/dispatch && mix test --include integration)
(cd desktop && npm test && npm run check && npm run build)
(cd desktop/src-tauri && cargo test --locked)
```

**Merge rule:** complete model checks and negative controls **first**, then
runtime refinement and UI checks; after both are green for the exact head,
review and merge. Do not close the original three #202 review threads until
the accepted corrective commit reaches `main`.
