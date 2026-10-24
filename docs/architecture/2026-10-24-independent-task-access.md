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

The legacy AgentCore.Attempts API retains compatibility/descriptor-validation
behavior. New generic recovery decisions, monitored worker ticks and task-read
rules live in TaskCore; the durable coordinator does not use the legacy pure
lease reducer as a persistence or proof service.

## Acceptance and remaining work

Tests cover separate permissions, unknown/wrong actions, tenant/principal/
task scope, stale revisions, revocation, offboarding, governance signing,
duplicate signed delivery and replay/restart. Signed-ledger integration is
added to task_agent_run_intents_test.exs.

This is a staging prerequisite, not staging acceptance. The implemented
[recovery, tools and result custody](2026-10-24-execution-recovery.md) still
require native integration, concrete trusted host authentication/verification
and two distinct real backend conformance runs. Fake adapters are not real
backend evidence. No production cutover is authorized or performed.

## Staging delivery bridge

TaskCore.Dispatcher now implements generic durable-register/claim/recheck/launch/
attach delivery over trusted host ports. AgentOpsStore.Coordinator binds those
ports to actual PostgreSQL CAS and the approved AgentCore adapter contract.
enqueue_all reconstructs pending work by scanning current committed run intents;
interrupted scans are retried using stable signed effect IDs, with no independent
business log or lossy enqueue acknowledgement.

The bridge requires environment() == :staging and explicit host context, consent
and sanitized backend-reference functions. An opt-in monitored worker is now
available; no endpoint or production application startup is added. Claims use
at most two attempts within one duration budget; retries of ambiguous effects
require independent reconciliation. Duplicate delivery of a leased row
never launches again, regardless of time elapsed. Authorization is checked again
after claim before launch. Invalidated claims are fenced for cancellation.

Six deterministic dispatcher tests inject duplicate enqueue/delivery, revoked
authority before/after claim, a lost backend response and attachment failure.
These are failure-path tests, not real backend or distributed database evidence.
The durable reconciliation, bounded candidate custody, typed read proxy and
opt-in worker are described in the recovery architecture. Their host proof and
transport authentication callbacks have no permissive defaults. withdraw/3
fences invalidated runs and requests termination; only a subsequently verified
final observation can confirm cancellation. Expiry alone proves no absence.

## Local validation

On 2026-10-24, both cores were copied outside the umbrella and compiled with
`mix compile --warnings-as-errors` using the pinned Elixir 1.19 / OTP 27 runtime.
All 87 TaskCore tests and 23 AgentCore tests passed via `mix test`. The
AgentCore Mix project now keeps umbrella paths only inside an actual umbrella.
These checks do not replace signed-ledger integration, PostgreSQL acceptance
or live backend conformance. Hosted jobs remained queued at this update.
Target configuration is tracked separately in [dev-ops PR #5](https://github.com/larsbx/dev-ops/pull/5).
Its entries remain disabled; connection setup and real backend conformance are
not claimed by this implementation. Do not invent or publish approved profiles.
