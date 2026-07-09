# Phase 1B — Membership lifecycle + capital-account fold

> **Status: IN PROGRESS** (started 2026-07-09). Scope is strictly the hand-off's Phase 1B
> (§2.2–2.3); acceptance = hand-off §6 items **[1B] 10–11**. Gate honored: 1A acceptance
> passed in full before this began (`docs/phase1a_plan.md`).

The in-conversation specs 00–13A are still not in this repository (SUBSTRATE.md §8), so this
plan is grounded in the hand-off text plus the 1A decisions already recorded in SUBSTRATE.md.
Every point where the hand-off under-determines governance/economic semantics is **flagged**
below rather than silently invented; each is representable now and enforceable by the 1D
governance workflow later — the same posture 1A took for `KeyRotated`/`CharterConstantDeclared`.

## Settled decisions

- **Source of truth stays the canonical log; membership state is a pure fold.** The membership
  lifecycle is an exhaustive, explicit transition table (`Membership.Lifecycle`, pure data +
  pure `apply/2`) used by both the queryable projection (`Projections.Membership`) and the
  **append-time gate**: illegal transitions are rejected *before persistence*, via the
  log-dependent validity hook the 1A type registry was designed for (`validity_check`, 09
  gated-N). The gate state is itself a pure fold of the log prefix, held by the single
  serialized appender and rebuilt on recovery — determinism is preserved end to end.
- **FLAGGED DEVIATION — AshStateMachine not adopted for the lifecycle.** The hand-off sketch
  names AshStateMachine, but 1A's store decision (SUBSTRATE.md §3, §5) explicitly rejected
  action-re-execution as the determinism story: substrate state must be a pure fold over
  canonical bytes, and the *enforcement point* for transitions must be the append gate (or
  illegal events could enter the eternal log and every replayer would need the same business
  logic to skip them). An Ash resource with AshStateMachine would be a second, non-canonical
  enforcement locus with nothing reading it yet (the stake-view UI is a later cold-start step —
  hand-off §5). The hand-off's *substance* — exhaustive, explicit transitions, each a signed
  event — is delivered by the pure table plus a property test over the full states × events
  matrix. Ash enters when the first read-side consumer does; the projection is the seam it
  will materialize from. Recorded in SUBSTRATE.md alongside the 1A signed-core deviation.
- **Identity:** a member (person) is `member_id` bound to an Ed25519 pubkey by
  `MemberRegistered` (self-signed: a declared signer's pubkey must equal the registered
  pubkey). `KeyRotated` (1A) rotates it; the projection tracks the current key. Membership is
  **(member, entity, class)** — dual membership is two membership records, one account each,
  never merged (hand-off §2.2). Entities are declared by `EntityRegistered` with
  `class ∈ {carriers_coop, workers_coop, mechanics_coop}` (master_design §3 via hand-off).
- **Everything chapter-scoped:** gate and projections key by `chapter_id` throughout
  (a member/entity/membership exists *within a chapter*); streams stay chapter-prefixed. The
  type registry gains one stream spec, `{:payload_fields, prefix, [f1, f2]}`, for
  per-(member, entity) streams.
- **Lifecycle machine** (exhaustive; anything not listed is illegal and rejected at append):

  | Event | From | To |
  |---|---|---|
  | `MembershipInvited` | *(none)* | `invited` |
  | `MembershipProbationStarted` | `invited` | `probationary` |
  | `MembershipConfirmed` | `probationary` | `member` |
  | `MembershipDeparted` | `invited`, `probationary`, `member` | `departed` |
  | `MembershipRetired` | `member` | `retired` |
  | `MembershipFloorExited` | `member` | `floor_exited` |
  | `MembershipDeceased` | `probationary`, `member` | `deceased` |

  Terminal: `departed | retired | floor_exited | deceased` — all are **redeemable-account
  states** (acceptance item 10); `deceased` additionally routes the account to the estate
  (`estate_ref`). **FLAGGED extrapolations** beyond the hand-off's arrows (which only exit
  from `member`): invited→departed (declined invite), probationary→departed (washout),
  probationary→deceased. Cure/hardship states are 1C (they belong to the floor machinery).
  Re-joining after a terminal state is an **open question** (not allowed in 1B; flagged).
- **Signer roles per event are PLACEHOLDER governance semantics** (who *may* author is the 1D
  validity workflow): steward-authored (`"steward"`): invite, floor-exit, deceased, entity
  registration, patronage, accrual-rule activation, redemption events; member-authored
  (`"member"`): probation start, retire, depart, member registration; `MembershipConfirmed`
  is dual-signed (`"member"` + `"steward"`) — exercising the 1A multi-role envelope in
  production types. **Real check now:** for every member-role signature on a membership event,
  the gate requires that signer's pubkey to equal the member's currently registered key.
  Steward keys have no registry yet (1D).
- **Capital accounts** (hand-off §2.3): per (chapter, member, entity); a pure fold
  (`Projections.CapitalAccounts`) in exactly the 1A projection shape.
  `account(member, as_of) = fold(rule_vN, events ≤ as_of)` via `Log.replay(…, as_of:)`.
  - **Rule versioning is in-log:** `AccrualRuleActivated{rule_id, params}` activates a rule
    (per chapter) *forward*; rule implementations are pure modules in a code registry
    (`Capital.AccrualRules`; tests may inject via app env, as with event types). Every account
    entry records the `rule_id` that credited it; activating a new rule **never** touches
    prior entries — reproducibility is a property of the log alone.
  - `PatronageRecorded{member_id, entity_id, kind, amount_minor, source_ref?}` — gate requires
    a registered, **active** membership (`probationary` or `member` — FLAGGED placeholder:
    probationary patronage counts), an active accrual rule for the chapter, and
    `amount_minor > 0`. Money is integer minor units (canonical profile forbids floats).
  - Placeholder rule `capital-accrual-v1` (linear): `credited = amount_minor ×
    weight_bp(kind) / 10 000`, weights + default from activation params — **all PLACEHOLDER,
    awaiting charter declaration**; the formula is a parameter, never hardcoded.
- **Redemption: data structures now, workflow later** (hand-off §2.3). Types + fold state
  only; no payout engine. `RedemptionScheduleOpened{member_id, entity_id, years,
  annual_cap_minor, method: "fifo"}` — gate: account state terminal/redeemable, no open
  schedule. `RedemptionPaid{member_id, entity_id, amount_minor}` — gate: schedule open,
  amount > 0; the fold consumes accrual entries **FIFO** and tracks `redeemed_minor`.
  `SinkingFundContributed{entity_id, amount_minor}` — per-entity sinking-fund balance,
  informational accounting in 1B. Annual-cap/amount-vs-balance enforcement is **deferred
  workflow** (needs as-of capital evaluation inside the gate); the data model carries
  everything it needs. Death-to-estate: `deceased` + `estate_ref` on the account.
- **KeyRotated stays ungated** (1A tests append it freely; who may rotate is 1D). New 1B
  types are the first gated ones.

## Build steps (TDD — tests with/before each module)

1. **Plan doc** (this file) — commit.
2. **`Membership.Lifecycle`** — states, exhaustive transition table, `apply/2`,
   `terminal?/1`. Property test: for every (state × lifecycle event) pair, `apply/2` matches
   the table exactly — legal pairs transition, all others reject.
3. **Type registry + constants** — the eleven 1B production types above;
   `{:payload_fields, …}` stream spec; `Constants.entity_classes/0`,
   `Constants.default_accrual_weight_bp/0` (PLACEHOLDER-flagged).
4. **`Projections.Membership`** — chapter-scoped fold: entities, members (current key),
   memberships (class + lifecycle state). Doubles as the append-gate state.
5. **`Protocol.Validity`** — the realized 1A hook: per-type log-dependent checks against the
   gate state (registration existence/uniqueness, transition legality, member-key
   authenticity, class match, active-rule presence, schedule open/closed, positive amounts).
6. **Log integration** — appender state becomes `{head, gate}`; `recover/0` folds both in one
   pass; the verify phase threads the gate through the batch in order (intra-batch
   visibility: event N sees N−1) and rejects the whole batch on the first violation — appends
   stay all-or-nothing, before persistence.
7. **Gate tests over the log** — unregistered entity/member rejected; duplicate registrations
   rejected; every illegal transition rejected pre-persistence (log unchanged, chains intact);
   dual membership across two entities works; wrong member key rejected; batch atomicity
   (later-invalid event aborts the earlier-valid one); chapter isolation (same ids in another
   chapter are independent).
8. **Capital engine** — `Capital.AccrualRule` behaviour, `Rules.LinearV1`,
   `Capital.AccrualRules` registry, `Projections.CapitalAccounts` fold, `Capital` query API
   (`account/4`, `balance/4` with `as_of:`). Tests: accrual math under v1; rule change applies
   forward only (v1 entries byte-identical after v2 activates — compared via as-of replay);
   per-entity accounts under dual membership; every terminal exit reaches a redeemable
   account (departed/retired/floor-exited/deceased-with-estate); balance independently
   reproduced by a test-side fold over `read_all` **and** over a verified `export_stream`
   (acceptance item 11's "independent computation").
9. **Redemption structures** — schedule open/payments/FIFO consumption/sinking fund tests;
   deceased → estate routing.
10. **SUBSTRATE.md §11** (Phase 1B: identity/membership model, the AshStateMachine deviation,
    accrual-rule versioning, redemption structures, gate architecture, new placeholders,
    updated §7 member-export answer, §10 acceptance status for [1B]) — commit.

## Acceptance / verification (hand-off §6 [1B] items 10–11)

- `mix test` green including: exhaustive transition matrix property; all gate rejections
  pre-persistence with chains verifying afterward; dual membership; all four exit types reach
  redeemable accounts; capital fold purity (replay twice ⇒ identical; as-of stable);
  rule-version forward-only; balances reproduced independently from events alone (read_all
  fold + export fold); redemption FIFO consumption; chapter isolation.
- `cargo test` still green (no canonical-profile change — 1B adds *types*, not encoding).
- Existing 1A suite untouched and green (no regression; KeyRotated ungated).

**Gate:** nothing from 1C starts until the above pass.
