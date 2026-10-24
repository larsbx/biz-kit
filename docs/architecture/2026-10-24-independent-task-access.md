# Independent task access (staging prerequisite)

TaskCore.Access defines governance-signed TaskAccessGrantedV1 and
TaskAccessRevokedV1. Permissions apply to people, services and agents.
Each grant permits exactly read or execute for one principal, chapter,
tenant, project, task and exact task revision/source event. Task changes
require new grants. Grant identifiers are locators, never bearer tokens.
Existing TaskPrincipalOffboardedV1 revokes both permission kinds.

A suggester grant and a signed run intent do not grant read or execute.
TaskCore.AgentRuns.authorized?/3 checks fresh runnable intent and both
independent permissions for the principal bound by that intent. runnable?/2
remains an intent-only compatibility check, not a launch authorization API.

The host must authenticate principals and supply current committed replay,
serialize authorization at disclosure/launch/tool/custody boundaries, enforce
consent and approved profiles, and propagate revocation/cancellation to
running executions. These pure rules do not close a host TOCTOU window.
No endpoint is exposed and no executor is enabled in this contribution.

## Placement

Generic task permissions, task revision checks and offboarding live in
TaskCore. AgentCore owns execution-profile/adapter negotiation; no framework,
model, vendor, image, container or hardware policy is added to task events.
Database CAS remains an operational host adapter in the existing governed
database; it never becomes a business ledger.

The existing AgentCore.Attempts reducer contains further potentially reusable
lease/recovery mechanics. Extract those into a generic TaskCore execution
module before adding a non-agent worker; retain compatibility for existing
callers and keep profile validation at the adapter boundary. This change
does not claim that extraction is complete.

## Acceptance and remaining work

Tests cover separate permissions, unknown/wrong actions, tenant/principal/
task scope, stale revisions, revocation, offboarding, governance signing,
duplicate signed delivery and replay/restart. Signed-ledger integration is
added to task_agent_run_intents_test.exs.

This is a security prerequisite, not a dispatcher or staging acceptance:
ledger-derived durable outbox ingestion/checkpointing, a worker using SQL CAS,
backend idempotent launch and immutable-effect lookup, abandoned-execution
reconciliation, typed tool proxy, bounded result custody and two real backend
conformance runs remain required by issue #92. Fake adapters are not real
backend evidence. No production cutover is authorized or performed.

## Staging delivery bridge

TaskCore.Dispatcher now implements generic durable-register/claim/recheck/launch/
attach delivery over trusted host ports. AgentOpsStore.Coordinator binds those
ports to actual PostgreSQL CAS and the approved AgentCore adapter contract.
enqueue_all reconstructs pending work by scanning current committed run intents;
interrupted scans are retried using stable signed effect IDs, with no independent
business log or lossy enqueue acknowledgement.

The bridge requires environment() == :staging and explicit host context, consent
and sanitized backend-reference functions. No scheduler, endpoint or production
application startup has been added. Claims use one attempt; retries of ambiguous
effects require independent reconciliation. Duplicate delivery of a leased row
never launches again, regardless of time elapsed. Authorization is checked again
after claim before launch. Invalidated claims are fenced for cancellation.

Six deterministic dispatcher tests inject duplicate enqueue/delivery, revoked
authority before/after claim, a lost backend response and attachment failure.
These are failure-path tests, not real backend or distributed database evidence.
Ongoing cancellation polling, verified termination/absence receipts, automated
cross-crash adoption, typed tools, result custody and full worker supervision
remain open. In particular, expiry never becomes proof of backend absence.
