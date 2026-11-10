# Verification boundary

This release contains two original pure state-transition kernels, a conditional Lean adapter wrapper, a finite adapter model and a local HTTP/SQLite acceptance pilot for the proposed research exchange. The pilot authenticates configured local credentials and can transfer disposable fixture credits under its controlled checker profile. A passing receipt does not establish a public service, production remote-agent identity, physical compute consumption or external financial authorization.

## What the Lean proofs establish

The functions in `formal/lean/ResearchExchange/Reward.lean` and `Reservation.lean` are executable Lean implementations. Their theorems refer directly to these functions, including the dispatcher `step`. Induction over `Reachable` establishes safety and conservation for any finite number of their actions and arbitrary natural-number values, under the stated definitions.

The reward kernel represents **one already funded reward slot** and two participant destinations. Its initial escrow is part of the initial allocation; this release does not implement or prove a transfer that funds that escrow. Acceptance consumes escrow and credits one destination atomically within a pure transition. An admitted candidate contains the worker, lease generation, all four binding components, the artifact identifier, admission time, and original lease expiry. That whole candidate is immutable after admission.

The proofs concern Lean's definitions. Native execution of the generated executable additionally relies on Lean's compiler and runtime behaving correctly; the differential tests exercise that path but do not prove compiler correctness.

The reservation kernel represents **one compute reservation**. Cancellation while execution is running retains the held amount. A trusted stop acknowledgment changes phase; only a subsequent valid settlement can debit actual cost and return the unused balance. A settled reservation is terminal. Invalid actions leave state unchanged.

The exact semantics, including deadline boundaries, are defined in `formal/lean/MODEL_CONTRACT.md`. The theorem registry lists the actual symbols submitted to axiom inspection and proof export. The generic receipt captures the reviewed source digest, so a changed target statement or implementation cannot reuse the same reviewed source identity.

### Conditional adapter wrapper

`formal/lean/ResearchExchange/Adapter.lean` wraps an existing `Reward.State` with a row version, verifier enablement/epoch and an optional settlement candidate. Configuration fixes the reward configuration, exact verifier principal and approved profile. A prepared verification carries the complete candidate, profile, version, authority epoch and a checked-evidence fact.

An atomic modeled commit requires an authenticated configured verifier, currently enabled authority at the same epoch, a checked exact profile, the current row version, the same admitted candidate and no existing settlement. It calls `Reward.accept` and publishes the resulting reward state, matching settlement and incremented version together only if that core transition actually changes state. Effective revocation disables the verifier and advances its authority epoch; repeating revocation of an already disabled grant is a no-op and does not alter the reward row version.

The registry expands from 31 original kernel properties to **63 properties: 31 original plus 32 wrapper obligations**. The wrapper covers unauthorized/unchecked/mismatched/stale refusal, settlement correspondence, conservation, retry and response-loss safety under its definitions. It begins from a supplied valid admission state; it does not prove that the HTTP worker routes establish authenticated admission. The authenticated and checked Booleans still stand for facts established outside Lean, and atomic durable publication is an assumption. These theorems are not a proof of Python, token hashing, proof-checker truth, SQL transactions or operating-system recovery.

The six required Lean negative controls comprise the original four and two adapter-specific refusals. The two reviewed true fixture theorems exercise exact export checking and valid-proof/wrong-target rejection; their truth is not a proof of the HTTP service.

## Evidence classes

| Evidence | What it supports | What it does not establish |
| --- | --- | --- |
| Lean theorem and dependency replay | A proposition about the named executable Lean definitions, subject to approved axioms and checker correctness | That a deployed HTTP service, database or Python translation implements the same transition atomically |
| TLC finite-state exploration | Safety for all reachable states within the explicitly declared finite model | Unbounded arithmetic or arbitrary numbers of workers and slots, fairness, progress or liveness |
| Quint scenario and mutant tests | That the chosen behaviors occur and deliberately broken rules produce detectable counterexamples | A replacement for complete finite-state exploration or a universal theorem |
| Python unit and Lean/Python differential tests | Agreement on the actual tested inputs and traces | A formal refinement proof of the Python interpreter or reference implementation |
| Authenticated loopback HTTP and SQLite crash/concurrency tests | Observed principal/role/scope separation, exact checked-candidate admission and atomic fixture-credit persistence in the tested local profile | Production identity, encrypted remote transport, PostgreSQL/failover behavior, an arbitrary-proof sandbox, or external financial settlement |
| Source and runtime hashes | Identification of bytes checked in a trusted local execution | Proof that an untrusted machine executed a checker honestly, or a signed remote attestation |

The adapter Quint profile requires exhaustive safety for its finite model, ten deterministic scenarios and nine intentional fault counterexamples. The current graph has 293,584 reachable states. It bounds one admitted candidate, two potential worker recipients, one verifier, two prepared request slots, one prefunded credit and limited versions/epochs. Its conservative environment includes grant rotation and version-only interference. Changed-payload request-ID conflicts are a concrete adapter-test obligation outside that finite model. An interrupted exploration, timeout, parser error or checker startup failure cannot count as a successful mutant.

Counts describe the checked model and required profile. The adapter suite implements 18 mandatory checks, and its runner rejects missing or skipped tests. A fresh source revision is accepted only by its complete exact-revision receipt, including the runtime acceptance lane; the existence of tests and model counts does not certify a new revision or deployment.

## Explicit assumptions

1. **Trusted positive authority inputs.** `trusted = true` for acceptance means an authenticated verification adapter has established all required evidence. The pure kernel proves how such an input is handled. It does not establish the premise. The separate pure trace runner intentionally accepts it for model tests. The HTTP pilot does not accept it: only its internal controlled checker path can construct a positive acceptance after checking stored bytes and rechecking current authority inside the commit transaction.
2. **Trusted stop and cost observations.** A trusted stop acknowledgment means execution has actually ended. The supplied settlement cost must come from the authorized meter. The model does not observe a process, a clock, hardware, electricity, token usage or a bill.
3. **Identifier interpretation.** Natural-number fields represent authenticated principal IDs and immutable content, target, environment and policy identities. Equality is mathematical equality in the model. The pilot derives principals from hashed opaque credentials, bindings from immutable configuration and artifact commitments from copied bytes. Correct hashing, canonical serialization, credential provisioning and exact source/profile binding remain concrete implementation and trusted-operator obligations, not Lean theorems.
4. **Atomic application.** One call to `step`, or to the wrapper's successful commit, is one atomic state transition. The pilot implements a short `BEGIN IMMEDIATE` transaction, version fencing and unique settlement constraint, persisting state, event and request response together. Tests must exercise concurrent independent connections and real process death. SQLite/OS durability and faithful Python execution are still assumptions; a stale read followed by an unconditional write would not satisfy the modeled boundary.
5. **Fixed configuration and scope.** The configured target, reward and participant mapping do not change during a trace. The first executable examples use distinct participant IDs. The arithmetic conservation proofs themselves do not establish account separation or a global supply limit.
6. **Trusted local execution.** The verifier runs reviewed source on a trusted local host, with a caller-supplied approved source digest. Before/after hashing is not a hostile-host defense or a filesystem race-proof snapshot. Use a genuinely immutable build input and separately controlled verifier for public submissions.
7. **Proof foundations.** The allowed axiom set is `propext`, `Classical.choice`, and `Quot.sound`. The audit rejects any other transitive axiom name, including sorry or native-computation axioms. The operating system, host runtimes and the correctness of the proof checkers remain part of the execution trust boundary.

## Scope against the architecture obligations

The architecture's C-01 (single reward), C-02 (same evidence binding), C-03 (stale lease fencing), C-09 (reward retry), C-12 (held compute funds), and C-13 (timely admission survives verifier delay) are addressed within these kernels. C-04 and C-11 have **local conservation and no-overspend results**, not a proof of global quota allocation or issuance. C-05 has exact modeled binding and a source-digest gate, not a full repository/artifact authentication service.

C-06 has local proof-runner and controlled-pilot checks that refuse failures, timeouts, missing success markers, unapproved axiom dependencies and a nonapproved artifact digest. C-07 has local worker/verifier credential separation with exact roles/scopes/principal checks. C-08 has a fixed approved source/toolchain/profile identity. C-10 has local credential enablement and epoch fencing, including a required revoke/regrant race test. None of these establish platform production identity, arbitrary dependency revision handling, or revocation of published proofs and their dependent artifacts.

Local durable transactions, canonical request-ID conflicts and process restart/retry are now implementation and required-test responsibilities of the pilot. Production/distributed recovery, multiple-slot accounting, scheduling fairness, project/global verification budgets, arbitrary-proof sandboxing and remote receipt signatures remain extensions. Rejection and reassignment after failed verification are also absent: an admitted candidate remains frozen in `submitted`; failing its check does not release escrow, reopen a lease or replace its evidence. A future closure/reissue transition needs its own invariants.

## Concrete local pilot boundary

`adapter_pilot/` binds only `127.0.0.1`. Worker routes lease/submit/read; the separately credentialed internal verifier route triggers actual checking of stored immutable bytes. Tokens are provisioned offline, only domain-separated hashes enter the database, and authentication derives worker identity rather than trusting JSON. Current role, scope, enabled status, exact configured verifier principal and credential epoch are checked again inside the write transaction after proof checking. Actual grant changes advance the epoch; an old verification cannot survive a revoke/regrant cycle.

The approved artifact is the fixed reviewed export of `forall n : Nat, n + 0 = n`; a different valid arithmetic export is the wrong-target control. The runtime requires the approved byte hash before invoking the two pinned checkers. It accepts no uploaded Lean source, import graph, tactics, commands, executable paths, verifier receipt or profile. The profile preparation step builds reviewed repository source under trusted operator control; it is not a contributor execution path.

The independent checkers run on the same trusted host. Their success checks a trivial fixed theorem and the controlled evidence path, not a submitted research result or deployed adapter correctness. SQLite receipts are unsigned local records. The fixture's initial escrow is assumed, and moving those fixture credits does not issue service credits or settle a real obligation.

Required recovery acceptance uses actual `os._exit` in the service process immediately before commit and immediately after commit but before response. The former must leave no payout/event/request receipt; the latter must preserve all three and return the same result after restart. Test failpoints and bounded pause controls are trusted process configuration, never selectable through HTTP fields or headers. Those tests do not simulate hardware power loss, networked filesystem behavior or replicated-database failover.

The original reservation kernel is still independent. No pilot route starts computation, observes real termination, accepts meter results or debits compute costs.

## Next production integration gate

The next first-party host adapter must carry this narrow operation through existing CoopSubstrate/AgentCore authorization, approved execution profiles and artifact custody, with PostgreSQL operational persistence. `ProofBankCore` remains an inert contract/blueprint core. Reuse the signed business admission path; do not introduce a parallel business writer. Hawala/TigerBeetle retains real financial authority, so a SQLite transaction or proof-check result cannot independently authorize a production spend.

Require a reviewed representation relation from production records to formal state, admission-time credential/grant revocation, exact candidate/profile binding and independently concurrent/crash-recovery tests under the real storage profile. If financial effects cross transactional boundaries, preserve original effect IDs and provider reconciliation/fencing; an SQL receipt alone is not proof of external settlement. Reproduce the complete proof/model/adapter profile at the exact integration revision and retain its evidence before promoting deployment claims.

The MCP and UTCP adapters should call that same domain operation. They should expose the candidate submission interface and status retrieval; the authority-bearing acceptance operation belongs to the controlled verification service. No protocol wrapper can substitute for that boundary.

Use the included traces as concrete integration fixtures. To claim refinement of the production service later, define the representation relation between persisted rows and these states, then establish that each committed operation implements a permitted transition. Database concurrency and crash tests are useful evidence toward that work but are not, by themselves, a universal refinement proof.
