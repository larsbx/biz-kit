# Company-structure primitive audit

Date: 2026-10-20. Status: **audit, no code changed**.

This audit lists every place the platform models who exists, who holds which
position, who answers to whom, who may do what, who owns what, and how groups
decide. It compares each with Keel's primitives (`apps/keel/docs/PRIMITIVES.md`)
and records the conflicts to decide, the gaps on both sides, and the defects
found along the way.

## Scope

| Code | Commit | Notes |
| --- | --- | --- |
| biz-kit `main` | `f3e2a61` | Includes `coop_substrate`, `dispatch`, `spruce_goose`, `keel`, `task_core`, `biz_kit_identity` and `biz_kit_cluster` as they are now. Imported apps that changed since the import were audited at this commit, not at their source repo. |
| truck-shop | `b12fcb1` | Not in biz-kit. |
| agent-runtime-platform | `9ccdc95` | Not in biz-kit. |
| spruce | `10b9479` | Not in biz-kit. |
| bizops-kb | `acf7051` | Prose, not code. |

Rechecked against `main` at `24d7947` (19 commits later, PRs #39–#44)
before review. None of the files cited for D1–D9 changed. The new blueprint
hierarchy (`2026-10-20-hierarchy-and-blueprints.md`) puts roadmap → workflow →
task on the ledger. That is a work tree, not an organization tree, so the
Unit row stands. Dispatch's signed capability document
(`2026-10-20-dispatch-capability-document.md`) is issued per role assignment,
which is consistent with C1.

Method: one read-only pass per codebase against a fixed checklist, then a
spot-check against source of every finding that this document relies on.
**✓** marks a claim confirmed directly at the cited location. Unmarked claims
come from the pass with their citation, and were not independently re-read.

## Summary

1. **Nothing uses Keel yet.** No app outside `apps/keel` refers to it or
   depends on it ✓. The integration decision names it as the authority for
   company structure (`2026-10-09-integration-decisions.md:70, 116, 257`) ✓, and
   so does agent-runtime-platform (`docs/REDIS_OPERATIONAL_FABRIC_SPIKE.md:65`) ✓.
   The adapter that would connect Keel to the ledger is planned but not built.
2. **Every codebase has its own party model, and they don't line up.** There
   are seven identity shapes:
   - ledger `member_id` keys;
   - `prn_` principals ✓;
   - dispatch `User` + `Participant` + `SERVICE`;
   - spruce_goose `Actor` (`:human | :agent | :system`) ✓;
   - truck-shop `User` + `Driver`;
   - spruce `Agent`;
   - bizops-kb roster rows.

   None of the code models can tell a person from an entity from an agent in
   one place. The `prn_` principal has no kind at all ✓.
3. **No code has a Body.** Every decision is made by one signer: ledger task
   events require exactly one ✓, and governance acts are 1-of-n. There is no
   vote, ballot or quorum anywhere in `coop_substrate/lib` ✓. One member, one
   vote exists only in the constitution text.
4. **No code has ownership stakes in units, or an organization tree.** Capital
   is a money balance. Scope is a fixed path: `chapter / tenant / project` or
   `project → roadmap → workflow → task`. No code has a reporting line.
5. **History is append-only on the ledger and mutable almost everywhere else.**
   - spruce_goose's legacy grants are hard-deleted ✓.
   - dispatch overwrites `status` and `ends_at`.
   - truck-shop overwrites role arrays and can destroy assignments.
6. **Agent accountability is partly there, and nothing can check it as a
   rule.** task_core makes every agent change trace back to a human-signed
   grant, and spruce_goose requires the first actor to be human ✓. But no party
   carries a kind, so "every agent answers to a non-agent" can't be checked.

## Matrix

Fit: **=** same, **≈** partial, **≠** conflict, **—** absent.

| Keel | coop_substrate | task_core + identity | dispatch | spruce_goose | truck-shop | agent-runtime-platform | spruce | bizops-kb |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Party** | ≈ `MemberRegistered` (person), `EntityRegistered` (3 coop classes). An entity cannot hold membership or stake. | ≈ `prn_` principal with no kind ✓; logins bound by `{issuer, subject}` | ≈ global `User`, a `Participant` per tenant, `SERVICE` principal with no backing table | ≈ `Actor` `:human \| :agent \| :system` ✓. Identity is self-declared (`--as`). | ≈ `User` and `Driver` unlinked, so one person can exist twice | ≈ implicit single human operator; agents are modes | ≈ `Spruce.Agent` with no owner | ≈ owner, admin, support contact, installer (prose) |
| **Unit** | ≈ chapter (flat); the federation exists in docs only | ≈ `chapter/tenant/project`, fixed depth 3 | — orgs are flat, no parent | ≈ project → roadmap → workflow → task (a work tree, not an org) | — `Part.location` is a string | — | — | ≈ departments (flat) |
| **Role** | ≈ signer roles (`member`, `steward`, `governance`, …); no grants | ≈ grant types: operator, reviewer, suggester, governance | ≈ `RoleDefinition` with `capabilities_json`, versioned and immutable once used | ≠ a role *is* a capability; no position identity | ≈ `[:technician, :warehouse_associate, :manager, :admin]` | ≈ Pi modes (decider, executive, …) | — | ≈ free-text job role |
| **Seat** | ≈ `RoleKeyDeclared` with no interval; one key is one seat | ≈ ledger grant with `active: bool`, no interval | ≈ `RoleAssignment` `[starts_at, ends_at)` ✓, plus scope | ≠ `Actors.Grant`, no interval, hard-deleted ✓ | ≠ array on the user row, overwritten | — | — | ≈ roster "log the date" |
| **Seat limit** | ≈ cannot orphan governance (min 1, counts keys) ✓ | — | ≈ only work-assignment exclusivity | ≈ last global admin protected ✓ | ≠ `can_add_users?` always true ✓ | — | — | ≈ vault key holders ≥ 2 (24.12d:37) ✓ |
| **Line :reports** | — | — | — | — | — | ≈ Executive acts on a Decider record (agent → agent) | — | — |
| **Line :delegates** | ≈ halaqa delegation narrows by depth, purpose and class; **revocation is a no-op** ✓ | ≈ operator → agent; depth 1; limits are fixed bounds, not the parent grant | ≈ break-glass narrows only (spec) | ≈ single-use permits and deployment authorizations | — | ≈ Decider → Executive scoped approval | — | — |
| **Line :mandates** | ≈ `EnvelopeDeclared` (a member's revocable dispatch envelope) | — | ≈ `LoadParty` / `StopParty` | — | — | ≈ human-approved deontic spec | — | ≈ Part A/B sign-off |
| **Stake / Class** | ≠ capital is money in minor units, FIFO redemption; membership class must equal entity class | — | — | — | — | — | — | — (13.64 Equity is a stub) |
| **Body** | ≠ one steward or governance signer ✓ | ≠ one signer per event ✓ | ≈ single approver (spec) | ≈ proposer ≠ approver on revisions | ≈ TLA+ `MinApprovers` (spec only) | ≈ Advocate/Skeptic/Judge prompt | — | ≈ owner alone |
| **Capability** | ≈ purpose prefix glob (`dispatch:*`) | ≈ fixed delegation kinds | ≠ closed flat set, no preorder | ≈ `*`/project plus "any role implies reader" | ≈ `:admin -> [:all]` | ≠ denylist of scopes and commands | ≈ tool allowlist | ≈ open/internal/restricted tiers |
| **Asset** | — | — | ≈ `Vehicle`, `Trailer` owned by an org | — | ≈ `Truck`, `Part` (no owner field) | — | — | — |
| **History** | = append-only, folded by `global_seq` | = append-only, `active: false` on revoke ✓ | ≠ status and `ends_at` overwritten | ≠ grants deleted, actors destroyable | ≠ destroy and update on history | — | ≈ `Turn` append-only | — |

## Conflicts to decide

| # | Conflict | Keel today | Elsewhere | Recommendation |
| --- | --- | --- | --- | --- |
| C1 | **Capability union** | `Org.can?/4` unions capabilities across all of a party's seats | dispatch forbids union: each request acts under exactly one assignment (`Dispatch.Access.Actor`, spec §23.3) ✓ | Adopt dispatch's rule. Change `can?` to act through one named seat, and keep the union version as an explicit read-only query. |
| C2 | **Time model** | `Date` intervals `[from, to)` | ledger: position in the log (`global_seq`), author timestamps are claims; dispatch: `utc_datetime_usec`; grants: `active` flag | Keep half-open intervals but make the instant type pluggable: an interval over ledger sequence numbers for the ledger, over datetimes for dispatch. A seat opens and closes by event, never by editing. |
| C3 | **Role = position vs role = capability** | Role is a position that confers grants | spruce_goose and truck-shop roles are capability names | Keep Keel's model. Map a spruce_goose role to a Keel Role with one grant, with no seat limit. |
| C4 | **Flat closed capability sets vs preorder** | `:* ⊒ k ⊒ {k, n}` | dispatch's closed list plus constraint keys; fixed delegation kinds | Keep the preorder and allow a closed vocabulary per domain. Add constraints (`requires_consent`, `self_only`, …) as conditions on a grant, not as new capabilities. |
| C5 | **Negative capabilities** | grant-only | agent-runtime-platform denylist | Keep grant-only. A denylist cannot be attenuated soundly. Express the executive's limits as a narrow grant. |
| C6 | **Party per key vs party with credentials** | one Party, many Seats | the ledger counts admin keys, so one person with two browsers is two seats; last-admin protection counts keys | Add credentials to a Party. Count seat limits and last-holder protection by party, not by key. |
| C7 | **Decisions** | Body with quorum, threshold, reserves, full consent for sale | every implemented decision has one signer | If one member, one vote is meant to hold, a Body needs a ledger event family: proposal, ballot, tally. Until then, record the gap: the constitution's voting rule is not enforced. |
| C8 | **Ownership as units vs money** | integer units of a class | capital accounts in minor units | Two separate stakes: membership (control, units) and capital (economic, money). Keel's Class can carry a unit or a currency. |
| C9 | **Two grant models in spruce_goose** | one append-only seat history | legacy `Actors.Grant` (hard delete) and ledger grants | Retire `Actors.Grant` under the single-source-of-truth plan, or at minimum close grants instead of deleting them. |

## What Keel lacks

These patterns already exist in the other codebases and are general enough to belong in Keel:

| Pattern | Where it exists | Proposed Keel form |
| --- | --- | --- |
| Seat **scope** (self, org, load, stop, assignment) | dispatch `RoleAssignment.scope_type` | `Seat.scope`, narrowing a role's grants to a subject |
| Seat **minimum** and last-holder protection | bizops-kb (≥ 2 key holders), ledger and spruce_goose (last admin) | `Role.seats: {min, max}` with invariant `min ≤ holders ≤ max` |
| **Separation of duties** | task_core `:dod_self_review` ✓; spruce_goose proposer ≠ approver; truck-shop TLA+ | `Body` or `Role` option: the actor may not be the subject or proposer |
| **Single-use, expiring permits** | spruce_goose `Derivations.Permit`, `Deployment.Authorization` (≤ 3600 s) | a `:delegates` line with `uses` and an interval |
| **Versioned, immutable role definitions** | dispatch: re-seeding can't widen authority | `Role.version`; a seat names the version it holds |
| **Membership lifecycle** (probation, cure, hardship, estate) | ledger `membership/lifecycle.ex` | a Class with lifecycle states that govern eligibility |
| **Party kind `:system`** | spruce_goose `ActorKind` ✓ | add `:system` and decide whether it counts as accountable |
| **Founding party** | spruce_goose genesis (must be human) ✓; ledger trust-on-first-use governance key | an invariant: the root seat is held by a person |

## Defects

These defects stand regardless of whether Keel is adopted.

| # | Where | Defect | Status |
| --- | --- | --- | --- |
| D1 | `coop_substrate/lib/coop_substrate/halaqa/buzz_bridge.ex:93-94` | `apply_revocation/2` returns its input: revoking a delegation changes nothing | **Not a defect.** Specified: revocation blocks new effects (`delegation_revoked`, test P18) and must never rewrite committed certificates (test P19; `docs/halaqa_buzz_integration_v1.md:63`). |
| D2 | `coop_substrate` `protocol/validity.ex` (no clause); `projections/membership.ex:486-488` | `CharterConstantDeclared` has no validity gate. Worse than first recorded: `author` is never a declared role, so after genesis any key could set finance caps, cure windows and harness gates. Overwriting is intended (honorarium clearance toggles 0 → 1). | **Fixed.** After governance genesis the author key must be a declared governance key, as the runbook already signs (`charter_constant_authority_test.exs`). |
| D3 | `coop_substrate` `protocol/type_registry.ex:45` | `CorrectionRecorded` is registered but no projection handles it, so corrections are stored and have no effect | **Not a defect.** Specified as an annotation, "not a rewrite" (`corrections_test.exs`); typed reversals exist where state changes (`CreditMemoIssued`). Demoting a machine-extraction proposal has no dependent state: promotion is a separate human-signed `FindingExtracted`. |
| D4 | `coop_substrate/lib/coop_substrate/enrolments.ex:137-148` | approving an enrolment needs only one governance key; no check that the approver is not the person being enrolled was found | **Not a defect.** A governance key can already declare any key, or grant any task role, for any principal without a request (`check_role_keys/2` is the only gate), so self-approval adds no power; refusing it would break the single-administrator case. A real control needs multi-signer governance (C7). |
| D5 | `coop_substrate` `protocol/validity.ex:163-165` | last-admin protection counts keys, so one person with two keys satisfies "not orphaned" and can be the only admin left | **Not a defect at the current policy.** The invariant is "never orphan governance" (at least one key), which counting keys guarantees. Keys vs people matters only for a minimum above one (see "Seat minimum"). |
| D6 | `coop_substrate` `RoleKeyDeclared` | `member_id` is optional and never checked against registered members, so a key can be bound to nobody | **Open, small.** The enrolment flow always binds the signed-in principal (`Approver.grants?/2`); only a hand-built governance command can bind nobody. The ledger cannot check principals until they move onto it (single-source-of-truth step). |
| D7 | `spruce_goose/lib/spruce_goose/actors/grant.ex:53-55` | revoking a grant destroys the row, which loses the record of who held authority when | **Open: needs a governed change.** Any fix changes the schema and `registry.ex`, and both are pinned constitutional roots (`schema`, `agent_charter` in `priv/kernel/shadow-event-roots.json`). A fix closing grants (`revoked_at`, `revoked_by`, a base filter, a partial unique index) passes the actor tests but requires re-pinning both roots. The ledger grants that replace `Actors.Grant` already keep history. |
| D8 | `spruce_goose/lib/spruce_goose/workflows/task.ex:85` | `Task.assignees` is free strings, not principals | **Not a defect.** Documented as scheduling metadata, "not the governed statement of the work" (`spruce_goose/docs/revisions.md:86`); nothing derives authority from it. Governed assignment is the ledger grant, which names principals. |
| D9 | `dispatch` `RoleAssignment.principal_type` | `SERVICE` principals have no accountable owner | **Open, no live path.** Nothing grants role assignments yet except seeds and tests, since the admin API is unbuilt. Resolution is planned: dispatch roles become governance-signed ledger grants (`2026-10-20-dispatch-capability-document.md`), which are accountable by construction. |
| D10 | truck-shop `lib/` | no policy authorizer anywhere, so any tenant user can run any action | **Blocked: truck-shop has never built.** It mixes Ash 2 and Ash 3 DSL, has syntax errors and no `mix.lock`, so a policy cannot be compiled or tested. Needs an Ash 3 bring-up first. |
| D11 | truck-shop `accounts/organization.ex:228-235` | `can_add_users?` always returns true | **Blocked**, as D10. |
| D12 | truck-shop `fleet/assignment.ex` | overlapping truck/driver assignments are not refused; the TLA+ invariants aren't enforced in code | **Blocked**, as D10. |
| D13 | spruce `resources/agent.ex` | its docs promise policies but there is no authorizer, and `max_turns` is never enforced | **Blocked: spruce has never built.** DSL errors, no migrations and no `mix.lock`. Needs a bring-up first. |
| D14 | agent-runtime-platform `bin/pi-executive`, `bin/pi-decider` | the Executive acts on an agent's (the Decider's) approval; the chain reaches a person only through the spec file | **Fixed.** The Decider runs only on a spec with `Status: approved` and a named `Approved-By:` (anything else defers); the Executive accepts records only from the Decider's `90-decisions` directory (`tests/test_pi_optimizer_gate.sh`). |
| D15 | bizops-kb `24.12d:61` | "Who approves adding or removing an employee?" is left blank in the sign-off form | **Not a defect.** It is a field under "Policies the owner decides", blank until the owner signs. |

## Recommended order

1. **Fix D2** (done: charter constants now need governance). D1 and D3
   turned out to be specified behaviour, as did D4, D5, D8 and D15. D14 is
   fixed. D7 needs a governed re-pin of two constitutional roots; D10–D13
   need truck-shop and spruce brought up to build first.
2. **Give the `prn_` principal a kind** (person, entity, agent, system). This
   is the precondition for agent accountability (C6 and the founding party).
3. **Decide C1** (one seat per request) and **C2** (instant type) in Keel
   before writing the Keel ↔ ledger adapter, because both shape its events.
4. **Add the Keel extensions** in the table above: seat scope, seat minimum,
   credentials, separation of duties, single-use permits.
5. **Build the Keel ↔ ledger adapter** as planned
   (`2026-10-09-integration-decisions.md:257`), starting with seats and
   grants, since every codebase has those, before ownership.
6. **Decide C7.** Either implement Bodies on the ledger, or state that the
   constitution's voting rule is aspirational.
