# Lean verification core

This directory contains two executable, sequential transition kernels and proofs
about those exact functions. It uses the Lean 4.35.0 toolchain with its bundled
`Std`; there is no mathlib or other downloaded package dependency. The JSONL trace
adapter additionally imports the toolchain's own `Lean.Data.Json` utilities.

## Build and execute

With the pinned toolchain available on `PATH`:

```sh
lake build
.lake/build/bin/exchange_trace < requests.jsonl
```

The executable reads one request per line and returns one response per line. The
response includes the supplied starting state and every subsequent state. See
`reference/TRACE_FORMAT.md` at the repository root for the complete protocol.
Numeric fields use arbitrary precision natural
numbers; duplicate keys, unknown/missing fields, non-integer numeric syntax, and
incorrect types are rejected. Diagnostics go to stderr and malformed requests
terminate the process with a nonzero exit status. It is a finite conformance
adapter, not an authenticated public service.

In environments where Lean cannot discover its own executable through procfs,
the repository verification runner supplies the documented, hash-checked
executable-path adapter. The proof kernel and its libraries remain the pinned
release binaries. Use the repository runner rather than changing proof options.

## What is proved

`proof_targets.json` registers 31 universal theorems. The repository verification
runner prints each theorem's transitive axiom dependencies and exports the
registered dependency closure for fresh kernel checking. Only the standard
logical axioms `propext`, `Classical.choice`, and `Quot.sound` are eligible for that
gate. The positive library contains no admitted proof or custom axiom.

| Kernel | Functions | Main guarantees |
| --- | --- | --- |
| Binding | Exact equality of four identifiers | Equality means the same target, input, environment, and policy |
| Reward slot | `lease`, `submit`, `tick`, `accept`, `step` | Admitted candidate immutability; stale/expired/misbound submissions refused; explicit verifier approval for the same candidate; retry idempotence; at most one payout on reachable states; conservation |
| Compute reservation | `reserve`, `start`, `cancel`, `stop`, `settle`, `step` | Conservation; insufficient credit refused; hold retained during cancellation; no refund while running/cancelling; trusted stop required; settlement idempotence and terminality |

The theorem `Reward.submitted_can_accept_after_delay` quantifies over arbitrary
clock delay after a timely valid submission. `acceptance_independent_of_clock`
also proves that advancing the clock commutes with acceptance. Thus later lease
expiry does not confiscate an already admitted candidate's eligibility when the
other acceptance guards hold.

`Reward.reachable_safe` and both `reachable_conservation` theorems use inductive
reachability from the explicitly defined initial states. Several stronger local
lemmas, including candidate immutability and conservation per step, apply to any
state under their written hypotheses. Supplying an arbitrary JSON state does not
prove it reachable.

The reservation guarantee is stated as the actual idempotence and terminality
properties. There is no claim based on a tautological phase-indicator counter.

## Positive and negative controls

`ResearchExchange/Examples.lean` contains 12 small kernel-evaluated positive
examples, including acceptance after expiry, payout retry, stale-generation
rejection, held funds during cancellation, settlement, and refund before start.
They compile as part of the normal library.

`negative/cases.json` describes excluded negative controls:

- A false proof that a stale generation can submit.
- A false proof that untrusted evidence can pay.
- A false proof that cancelling running work immediately refunds its hold.
- A theorem that compiles only by depending on an injected custom axiom, which
  the axiom gate must reject.

The negative files are intentionally absent from the normal library imports.
Rejecting them is an expected verification result; they must never be admitted
to make a build pass.

## Boundary and assumptions

These are two independent small kernels: one already prefunded reward slot and
one quota reservation. The funder balance is unchanged inside the reward model;
commissioning the escrow from a global ledger is not modeled. General
multi-slot/multi-reservation accounting is not proved.

Target, input, environment, policy, artifact, and worker identifiers are
uninterpreted naturals. The model checks equality and does not implement a hash,
signature, authentication protocol, theorem checker, or sandbox. `trusted=true`
is supplied by a trusted adapter only after the external verification or stop
condition actually holds. The theorems force that input to be present; they do
not establish its truth. Stop acknowledgment must mean computation has actually
stopped before settlement can refund unused funds.

Real commissioning requires distinct participant IDs. The pure transition core
allows equal IDs, and its safety/conservation proofs still hold; that degenerate
case routes payment to balance A. The JSON trace adapter accepts arbitrary core
configurations for boundary testing and is not a commissioning API.

Database transactions, concurrency, cryptography, honest metering, network
transport, distributed recovery, scheduling/liveness, compiler correctness, and
the JSON adapter are outside these theorem statements. Executable trace
agreement with a separate reference implementation is useful test evidence,
not a refinement proof for a production server.
