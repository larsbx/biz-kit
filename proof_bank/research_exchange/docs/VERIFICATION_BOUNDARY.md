# Verification boundary

This release implements and checks two local state-transition kernels for the proposed research exchange. It is a proof-first foundation for the coordinator. A passing local receipt does not create a public service, authenticate a contributor, establish physical compute consumption, or authorize a reward.

## What the Lean proofs establish

The functions in `formal/lean/ResearchExchange/Reward.lean` and `Reservation.lean` are executable Lean implementations. Their theorems refer directly to these functions, including the dispatcher `step`. Induction over `Reachable` establishes safety and conservation for any finite number of their actions and arbitrary natural-number values, under the stated definitions.

The reward kernel represents **one already funded reward slot** and two participant destinations. Its initial escrow is part of the initial allocation; this release does not implement or prove a transfer that funds that escrow. Acceptance consumes escrow and credits one destination atomically within a pure transition. An admitted candidate contains the worker, lease generation, all four binding components, the artifact identifier, admission time, and original lease expiry. That whole candidate is immutable after admission.

The proofs concern Lean's definitions. Native execution of the generated executable additionally relies on Lean's compiler and runtime behaving correctly; the differential tests exercise that path but do not prove compiler correctness.

The reservation kernel represents **one compute reservation**. Cancellation while execution is running retains the held amount. A trusted stop acknowledgment changes phase; only a subsequent valid settlement can debit actual cost and return the unused balance. A settled reservation is terminal. Invalid actions leave state unchanged.

The exact semantics, including deadline boundaries, are defined in `formal/lean/MODEL_CONTRACT.md`. The theorem registry lists the actual symbols submitted to axiom inspection and proof export. The generic receipt captures the reviewed source digest, so a changed target statement or implementation cannot reuse the same reviewed source identity.

## Evidence classes

| Evidence | What it supports | What it does not establish |
| --- | --- | --- |
| Lean theorem and dependency replay | A proposition about the named executable Lean definitions, subject to approved axioms and checker correctness | That a deployed HTTP service, database or Python translation implements the same transition atomically |
| TLC finite-state exploration | Safety for all reachable states within the explicitly declared finite model | Unbounded arithmetic or arbitrary numbers of workers and slots, fairness, progress or liveness |
| Quint scenario and mutant tests | That the chosen behaviors occur and deliberately broken rules produce detectable counterexamples | A replacement for complete finite-state exploration or a universal theorem |
| Python unit and Lean/Python differential tests | Agreement on the actual tested inputs and traces | A formal refinement proof of the Python interpreter or reference implementation |
| Source and runtime hashes | Identification of bytes checked in a trusted local execution | Proof that an untrusted machine executed a checker honestly, or a signed remote attestation |

## Explicit assumptions

1. **Trusted positive authority inputs.** `trusted = true` for acceptance means an authenticated verification adapter has established all required evidence. The pure kernel proves how such an input is handled. It does not establish the premise. Contributor JSON must never supply this field directly in a public service. The local trace runner intentionally accepts it to exercise both outcomes in tests.
2. **Trusted stop and cost observations.** A trusted stop acknowledgment means execution has actually ended. The supplied settlement cost must come from the authorized meter. The model does not observe a process, a clock, hardware, electricity, token usage or a bill.
3. **Identifier interpretation.** Natural-number fields represent authenticated principal IDs and immutable content, target, environment and policy identities. Equality is mathematical equality in the model. Collision resistance, canonical serialization, authorization and exact binding to repository objects belong to the adapter.
4. **Atomic application.** One call to `step` is one atomic state transition. Concurrent service requests must be serialized through a transaction, compare-and-swap, or an equivalent justified mechanism. A stale read followed by an unconditional write does not satisfy this assumption.
5. **Fixed configuration and scope.** The configured target, reward and participant mapping do not change during a trace. The first executable examples use distinct participant IDs. The arithmetic conservation proofs themselves do not establish account separation or a global supply limit.
6. **Trusted local execution.** The verifier runs reviewed source on a trusted local host, with a caller-supplied approved source digest. Before/after hashing is not a hostile-host defense or a filesystem race-proof snapshot. Use a genuinely immutable build input and separately controlled verifier for public submissions.
7. **Proof foundations.** The allowed axiom set is `propext`, `Classical.choice`, and `Quot.sound`. The audit rejects any other transitive axiom name, including sorry or native-computation axioms. The operating system, host runtimes and the correctness of the proof checkers remain part of the execution trust boundary.

## Scope against the architecture obligations

The architecture's C-01 (single reward), C-02 (same evidence binding), C-03 (stale lease fencing), C-09 (reward retry), C-12 (held compute funds), and C-13 (timely admission survives verifier delay) are addressed within these kernels. C-04 and C-11 have **local conservation and no-overspend results**, not a proof of global quota allocation or issuance. C-05 has exact modeled binding and a source-digest gate, not a full repository/artifact authentication service.

C-06 is addressed in the **local test runner** by refusing failures, timeouts, missing success markers and unapproved axioms. The reward model still assumes the authority adapter has mapped evidence correctly. C-07 (credential separation), C-08 (dependency revisions), and C-10 (revocation and dependent invalidation) are not implemented here.

Rejection and reassignment after an admitted candidate fails verification, crash recovery, multiple commissioned slots, cross-slot accounting, request idempotency-key conflicts, durable database transactions, revocation, scheduling fairness, project/global verification budgets, sandbox enforcement and remote receipt signatures remain explicit extensions. The first kernel's admitted candidate is terminal with respect to replacement; an invalid admitted candidate needs a future rejection/closure transition with its own invariants.

## Integrating the next layer

The server should convert a successful controlled check into a capability-scoped verifier result bound to the exact admitted candidate. It should load the slot under a database lock, apply the transition once, persist the resulting state and ledger event in the same transaction, and commit before responding. On a retry, it should read the already committed outcome. The implementation must also reject stale state versions; a model-level idempotent function cannot repair a non-atomic read/modify/write cycle.

The MCP and UTCP adapters should call that same domain operation. They should expose the candidate submission interface and status retrieval; the authority-bearing acceptance operation belongs to the controlled verification service. No protocol wrapper can substitute for that boundary.

Use the included traces as concrete integration fixtures. To claim refinement of the production service later, define the representation relation between persisted rows and these states, then establish that each committed operation implements a permitted transition. Database concurrency and crash tests are useful evidence toward that work but are not, by themselves, a universal refinement proof.
