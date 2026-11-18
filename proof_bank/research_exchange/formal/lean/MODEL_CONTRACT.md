# Shared executable kernel and adapter contract (revision 2)

This model retains TWO INDEPENDENT kernels and adds a conditional durable-acceptance wrapper around the reward kernel. It is not a global multi-slot accounting proof and does not combine rewards with compute reservations. All numeric domains in Lean are unbounded naturals. Quint instantiates explicit finite domains; the local SQLite pilot bounds credit totals and numeric database columns to signed-64-bit values while representing full digest commitments as Nat values in canonical JSON.

## Identity and binding

A `Binding` is the complete tuple `(target, input, environment, policy)`, each an uninterpreted natural identifier. Equality means exact equality of all four fields. A candidate is `(worker, generation, binding, artifact, submittedAt, leaseExpires)`. Worker IDs are natural numbers. Commissioning a real two-participant slot must require the parameters `workerA` and `workerB` to be distinct; the pure core does not enforce that commissioning rule. Its conservation, admission, and retry theorems hold even for equal IDs, in which case payout always routes to balance A. The funder is represented separately by a funder balance. Equality of IDs is an abstraction of correctly implemented authentication and collision-resistant commitments; neither is proved here.

## Reward slot

Configuration: `expected : Binding`, `reward : Nat`, `workerA : Nat`, `workerB : Nat`.

State: `now`, `generation`, `owner`, `expires`, `phase ∈ {open, leased, submitted, accepted}`, `candidate : Option Candidate`, `payouts`, `funder`, `escrow`, `balanceA`, `balanceB`.

Initial state is commissioned/prefunded: `phase=open`, no candidate, `payouts=0`, `escrow=reward`; initial funder and participant balances are parameters. This models one already commissioned slot.

Actions (invalid actions are exact no-ops):

- `tick(delta)`: advance `now` by `delta` only.
- `lease(worker, deadline)`: worker must equal workerA or workerB; deadline > now; no admitted candidate; phase is open OR phase is leased and now ≥ expires. Set phase leased, increment generation, set owner and expiry. A stale lease is never revived.
- `submit(worker, generation, binding, artifact)`: require phase leased, exact owner, exact generation, now < expires, binding = expected, no admitted candidate, and worker membership in the configured pair. Save candidate including submission time and lease expiry; set phase submitted.
- `accept(trusted, evidence)`: require phase submitted, `trusted=true`, evidence exactly equals admitted candidate, candidate binding = expected, candidate worker one of the configured workers, payouts=0, escrow≥reward. Set phase accepted and payouts=1; escrow decreases by reward, the candidate worker's balance increases by reward. **No current-time or current-expiry test is made.** Timely admission retains reward eligibility after clock advance.

The `trusted` input is an explicit boundary: it represents an authenticated verifier approval after checking the specified artifact against its exact target/input/environment/policy. The kernel proves the approval must be supplied and must name this exact candidate. It does not prove a Boolean represents a real verifier, an external theorem, or honest metering.

Proved universal properties: admitted candidate immutable under every action; admitted binding and admission timing valid on every reachable state; stale-generation submission is a no-op; untrusted or mismatched verifier evidence cannot pay; `payouts≤1`; acceptance idempotent on retry; funder + escrow + balanceA + balanceB conserved; timely candidate can still be accepted after arbitrary clock advances when the other acceptance guards hold.

## Compute reservation

State: `phase ∈ {idle, reserved, running, cancelling, stopped, settled}`, `available`, `held`, `spent`. Initial available credit is a parameter; held=spent=0.

- `reserve(cap)`: phase idle and cap≤available; available-=cap, held+=cap, phase reserved.
- `start`: phase reserved -> running.
- `cancel`: reserved -> stopped; running -> cancelling; otherwise no-op. No funds move.
- `stop(trusted)`: trusted=true and phase running or cancelling -> stopped. No funds move. Trusted input is an authenticated runtime stop/reconciliation acknowledgment.
- `settle(cost)`: phase stopped and cost≤held; available += held-cost; spent += cost; held=0; phase settled.

Proved properties: available+held+spent conserved for every transition and every reachable state; cancellation while running retains the full hold; settlement while running/cancelling is a no-op; untrusted stop is a no-op; an attempt to reserve more than the available balance is a no-op; settlement is idempotent, and every action on a settled state is a no-op. There is no separate settlement-event counter theorem: the terminal-state and idempotence theorems describe the actual implemented retry behavior.

## Conditional durable reward adapter

`ResearchExchange.Adapter` calls the existing `Reward.accept`; it does not implement a second reward transition. The wrapper begins from a supplied admitted reward state, so its reachability results do not establish that an HTTP worker was authenticated or that submission custody was correct.

Configuration adds an exact verifier principal and approved profile identifier to `Reward.Config`. Durable state contains `reward : Reward.State`, `version`, `verifierEnabled`, `verifierEpoch`, and `settlement : Option Candidate`.

A request identity contains `authenticated` and `principal`. A prepared verification contains the complete `candidate`, `profile`, captured `version`, `authorityEpoch` and `checked` fact. Mathematical identities abstract the concrete principal, source/profile and byte commitments; the model does not implement token verification or cryptography.

`commit(cfg, state, identity, prepared)` requires all of:

- Authenticated identity and exact configured verifier principal. Role and slot scope are part of that authentication premise.
- Currently enabled authority and equality of the prepared/current authority epochs.
- A positive checked-evidence fact and the exact configured profile.
- Equality of the prepared/current row versions.
- Exact equality of the prepared candidate and immutable admitted candidate.
- No existing settlement.

It then calls `Reward.accept cfg.reward state.reward true prepared.candidate`. If that call is a no-op, the complete durable state is unchanged. Otherwise it atomically publishes the resulting reward state, increments the row version once and records that exact candidate as the settlement. An invalid guard is an exact no-op. Publishing the reward change, version and settlement together is the abstract atomicity contract, not a proof that a particular SQL implementation satisfies it.

`revoke(state)` disables an enabled verifier and increments its authority epoch. It does not change the reward row version or balances. Revocation of an already disabled verifier is idempotent. The local runtime additionally provides trusted offline re-enablement, advancing the epoch on every actual enablement change; bounded grant rotation is exercised in the adapter Quint model and runtime acceptance. Current-epoch equality is always required at commit.

`settlementConsistent` states that either there is no settlement and zero payouts, or the settlement is the same admitted candidate in an accepted reward state with one payout. The wrapper's 32 registered obligations cover guard refusal, exact underlying reward-transition correspondence, settlement consistency, local conservation, candidate immutability, single settlement, revocation and retry/response-loss safety. The original kernels and the acceptance wrapper contribute 63 of the 76 registered properties. These claims require their stated premises and exact-revision axiom audit/export replay.

The formal settlement is a candidate-valued option, not a model of every concrete SQL column, HTTP response byte or permanent request-ID map. The Python pilot's canonical request binding and concurrent database/process-crash tests are separate implementation evidence. Lean does not verify the checker binaries, Python interpreter, SQL engine, durable storage or response transport.

## Terminal rejection and refund

`Closure.decide` accepts a typed positive, definitive rejection or inconclusive
verdict. Rejection requires the same authentication, checked-evidence,
profile, candidate, version and authority-epoch guards as acceptance. It
additionally requires a valid submitted candidate, no payout or prior effect,
and the positive original escrow in full. It atomically sets the phase to
`rejected`, zeroes escrow, adds it to the funder, records the candidate and
amount in a refund effect and increments the version. Worker actions and later
decisions preserve the rejected reward. Revocation can still change the grant.
Inconclusive evidence leaves the slot and all credits in place.

The closure proofs quantify over arbitrary finite decision and revocation
traces. They establish candidate immutability, conservation, terminal inertia,
one refund effect and zero payouts on every rejected suffix. The model assumes
authoritative verdicts and atomic publication, and treats one original slot as
one escrow. Canonical HTTP request binding and explicit new funding for any
replacement are concrete pilot obligations.

## Controlled artifact fixture

The two reviewed fixture theorems are `expected_fixture` (`forall n : Nat, n + 0 = n`) and `alternate_fixture` (`(2 : Nat) + 3 = 5`). Both are true and serve to test exact target binding. Operator preparation exports their actual dependencies and checks their axiom policies. The pilot profile approves only the expected export's exact bytes, source and checker identities; a valid alternate export must be refused.

Only the internal controlled-check path may construct the core's positive `trusted` input. The HTTP worker interface has no authority-bearing acceptance, checker-result, profile or receipt input. Replaying a fixed trivial theorem tests the narrow evidence boundary; it does not validate arbitrary research artifacts or establish an untrusted Lean-source sandbox.

## Explicit scope

The theorems establish safety of the named pure transition definitions under explicit premises. Production database atomicity, concurrent linearizability, network transport, worker isolation, verifier authenticity, cryptographic commitments, arbitrary proof artifact validation, liveness/fair scheduling, metering truth, multi-reservation and multi-slot conservation, and distributed recovery are not covered. The local HTTP/SQLite pilot supplies finite tests toward a concrete correspondence; it is not a formal runtime-refinement theorem or production financial authority.
