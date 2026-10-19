# Offboarding

Date: 2026-10-19. Status: **implemented**. Follows
[device revocation](2026-10-19-device-revocation.md).

## Decision

When someone leaves, or an agent is retired, an administrator ends
everything that principal holds in a project from the web view
([administration](2026-10-19-administration.md)), or in every project with
one command:

    mix coop.offboard <PRINCIPAL_ID> [--server URL] [--yes]

It lists what the principal holds in each project, asks once, and signs one
`TaskPrincipalOffboardedV1` per project with the governance key. Each event
ends, as of its admission, everything the principal then holds in that
project:

| Held | Ended as if by |
| --- | --- |
| operator grants (their devices) | `TaskOperatorRevokedV1` |
| suggester grants | `TaskSuggesterRevokedV1` |
| reviewer grants | `TaskReviewerRevokedV1` |
| delegations made **by** them | `TaskDelegationRevokedV1` (they already end with the delegator's grant) |
| delegations made **to** them (as an agent) | `TaskDelegationRevokedV1` |

One event per project, not one per grant, because what matters is the
outcome, not the list. Admission, not preparation, decides what ends, so a
grant appended between listing and signing ends too. A list of grant IDs
would leave it.

Nothing else changes:
- the principal, its identity bindings and everything it signed stay on the
  ledger, still attributed to it;
- other principals' grants, including the grants behind delegations they
  made to this principal, are untouched;
- governance may grant the principal afresh later. What ended stays ended:
  a new grant revives no delegation.

## The event

```elixir
"TaskPrincipalOffboardedV1" =>   # governance-signed; stream task_grants/<tenant>/<project>
  %{"tenant_id", "project_id", "principal_id"}
```

Admission:
1. a governance key declared for the chapter signs it;
2. `principal_id` is not empty;
3. the principal holds something in the project, else
   `:nothing_to_offboard`.

The fold deactivates exactly `Projections.Tasks.held_by(state, principal,
scope)`: the active entries of the four kinds above in that project whose
principal, or delegator, is the principal. Admission uses the same function,
so the event is refused exactly when the fold would change nothing.

Every check that reads a grant follows from the fold: commands are refused,
the person's feed sessions end at the event, and delegated agents stop.

## HTTP

```
GET  /api/v1/principals/:id                       (governance-signed read) → what it holds, per project
POST /api/v1/principals/:id/offboarding           {"governance_key_id", "chapter_id", "tenant_id", "project_id"} → the event to sign
POST /api/v1/principals/:id/offboarding/:held_id  {"signature"}
```

What a principal holds (its projects, device labels and keys) is for
administrators only, and preparing an offboarding would tell whether it
holds anything in a project (201 or `nothing_to_offboard`). Both the listing
and the preparation therefore need a **governance-signed request**:

    Authorization: CoopGovernance key="…", ts="…", nonce="…", sig="…"

The signature covers a canonical `CoopGovernanceReadV1` term binding the
method, path, time and nonce, as feed reads do. The nonce is spent in the
same store. The listing shows only the chapters in which that key is a
declared governance key, and preparation is refused for any other chapter.
A key that governs no chapter gets 401. The submission needs no header: it
names a held ID, which only the preparer was given.

The event is held for `{:offboarding, principal}` under the per-owner bound
of `Commands.hold/5`. Before it is submitted, the principal's pending
enrolment requests in that project are cancelled, so an old code cannot be
approved by mistake. That includes an approval already prepared and signed:
approval and cancellation run in turn in the `Enrolments` process, and
approval goes ahead only while the request is still pending. An approval
admitted before the cancellation is ended by the offboarding, since
admission decides what ends. A new request can still be made, and approved,
like any other.

Principal IDs are any non-empty string, so the client escapes every
reserved character when it puts one in a URL path (`Client.segment/1`).

`mix coop.offboard` uses `CoopSubstrate.Governance.Client`, as `coop.enrol`
and `coop.revoke` do. It signs a project's event only if the decoded
envelope offboards exactly that principal from exactly that project, signed
by its own key alone. If it stops part-way, running it again offboards the
rest; when nothing is left, it says so.

## Verification

- `OffboardingTest` (ledger, 9 tests):
  - everything the principal holds in the project ends: two devices, a
    suggester grant, a reviewer grant, and delegations by and to them;
  - the person's feed access ends, and the laptop and its delegate can no
    longer act;
  - another principal and another project are untouched;
  - only a declared governance key; refused when nothing is held, including
    a second time;
  - a fresh grant afterwards works, and the old delegation stays ended;
  - through the server: the per-project listing, a grant added between
    preparing and signing ends too, the wrong key or owner is refused, and
    pending enrolments are dropped, including an approval already prepared
    and signed;
  - governance reads: a declared key sees its chapters; another key, a
    stale or replayed request, or another path is refused.
- The generated task histories now offboard the operator, the agent and the
  delegate, and a coverage test checks that all three are reached. Every
  suggestion and delegation property holds over them, including "every task
  change traces to a live grant or delegation".
- `SpruceGoose.Web.OffboardingTest` (3 tests):
  - `mix coop.offboard --yes` across two projects against a running server;
  - the person's open feed ends;
  - a second run finds nothing;
  - the listing and preparation need a governance-signed request, and
    another chapter's governance sees nothing and can prepare nothing here;
  - the offboarder refuses an event it was not shown, and an impostor key is
    refused.

The Quint model needs no change: offboarding is several grants becoming
inactive at one point, which its properties already allow.

## Limits

- Identity bindings and sessions are left as they are. A signed-in person
  with no grants reads and signs nothing. Unbinding an identity remains an
  identity-layer action.
- Offboarding covers the task grants and delegations of the common ledger.
  Cooperative membership has its own lifecycle and is not touched.
