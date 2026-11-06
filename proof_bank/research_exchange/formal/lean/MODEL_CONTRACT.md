# Shared executable kernel contract (revision 1)

This model has TWO INDEPENDENT kernels, not a global multi-slot accounting proof. All numeric domains in Lean are unbounded naturals. Quint and the reference implementation may instantiate finite bounds for checking.

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

## Explicit scope

Sequential pure state-machine safety. Production database atomicity, concurrent linearizability, network transport, worker isolation, verifier authenticity, commitments, proof artifact validation, liveness/fair scheduling, metering truth, multi-reservation and multi-slot conservation, and distributed recovery are not covered by these theorems. A production adapter must separately demonstrate refinement to these functions.
