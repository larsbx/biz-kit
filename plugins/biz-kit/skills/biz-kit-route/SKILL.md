---
name: biz-kit-route
description: Route requests concerning the Biz-Kit producer-cooperative platform to the correct domain, authority boundary, and verification workflow.
---

# Biz-Kit request routing

Use the repository's current source and architecture documents as authority. Do not
infer deployed behavior from a proposal, pure core, imported snapshot, test fixture,
or passing unit test.

## Classify the request

Route to the narrowest owning capability:

- identity, principals, sessions, or grants: `biz_kit_identity`
- tasks, dependencies, evidence, review, or completion: `task_core` and `task_host`
- agents or adapter launches: `agent_core`, with TaskCore authorization revalidation
- signed canonical events or capital accounts: `coop_substrate`
- catalog, pricing, sales, inventory, orders, restaurant, fulfillment, dispatch, or
  accounting: the corresponding `*_core` and host/adapter
- operating procedures and reference material: `bizops_kb`
- proof obligations: `proof_bank`, Lean, Quint, and executable correspondence tests

If ownership overlaps, state each boundary and identify the single command-admission
path. Do not create a second writer or shadow source of truth.

## Preserve authority

Chat access is not authority. Separate:

1. observation,
2. suggestion,
3. proposal,
4. authenticated admission,
5. committed event,
6. projection,
7. independently verified completion.

Default to observation and proposal. Any requested effect must name the principal,
grant/scope, exact object and revision, command, confirmation rule, and expected
signed receipt. Reject or pause on ambiguity.

## Report evidence

For repository work, report the exact commit, checks actually run, inherited versus
introduced failures, formal-model status, and what remains unverified. Never equate
compilation, pure-model proof, or a synthetic adapter test with production acceptance.
