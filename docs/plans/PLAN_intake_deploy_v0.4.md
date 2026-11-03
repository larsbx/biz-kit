# PLAN_intake_deploy v0.4: Intake Kernel, biz-kit Native

Status: actionable · Supersedes: v0.3 · Implements: SPEC_dod_grammar v0.2
**DP-1 resolved (2026-11-03): A, delegate.** biz-kit pins oracles, verifies signed results and adjudicates closure. It never runs an oracle.

---

## 0. Changes from v0.3

These come from a review of v0.3 against `main` at `5cf60d3`.

| v0.3 | v0.4 | Why |
|---|---|---|
| `{id, description, oracle}` added to the criterion grammar, with no rule given | A **typed criteria rule** used only by V2 and catalogues. V1 keeps exactly two keys (§3.1). New obligation EXB-9a | `TaskCore.DoD.validate_criteria/1` requires `map_size(c) == 2` (`dod.ex:133`), so v0.3's shape is refused today. Widening that shared rule would let a `TaskDoDDefinedV1` carry an oracle that V1 completion ignores |
| `discriminating(ω)` defined over the *last* witness result | **The first non-error witness result for each ⟨ω, digest⟩ is final.** `discriminating` can only change from false to true. Withdrawing h(ω) is final (§3.2) | A later result could flip J3a after adoption, which is checked only once. Witnesses and verdicts now follow one slot rule |
| Oracle determinism was implicit | **Premise P-DET** (§3.3), with risk **R7, flaky ω** | First-wins slots make the result depend on arrival order unless ω is a function. J3a cannot detect flakiness |
| EXB-5: "held by a declared agent" | The signer must be a declared `agent` **when it signs**, not only when granted (§3.2, EXB-5) | A principal-kind declaration can be retracted (`projects.ex:226`), and principals can be offboarded |
| "Run ω@h from the bank" | **ProofBankCore catalogues candidates and admits nothing.** `TaskOracleRegisteredV1` is the only act that admits an oracle. ω's bytes live in custody under h(ω) (§1, §3.3) | `ProofBankCore.Portfolio` uses the same method enum, and its seeds are explicitly inert. Without this rule there would be two banks, and ω's source would be unconstrained |

### 0.1 Carried from v0.3 (changes from v0.2)

| v0.2 | v0.3 | Why |
|---|---|---|
| DP-1 open | **A**: evaluation is delegated to the swarm executor | TaskCore stays pure; evidence and judgment stay in different hands |
| P0 described abstractly | P0 status measured against `main` (§2) | Typed intake and ownership have landed |
| `eval(ω, input)` requests as signed events | **No request events.** Pending evaluations are a projection of state | One fewer protocol: a request is derivable, so storing it would be redundant |
| J3a (discriminating) checked per task at compile | J3a checked **once per oracle**, when a catalogue citing it is adopted | J3a is a property of ω, not of τ. This removes a round trip from every intake |
| `bank-gaps.txt` | Adoption is **refused** while any cited oracle is not discriminating, and the gaps are a projection | An invariant replaces a file that has to be kept current |
| Closure by verdicts alone | P1 keeps the existing reviewer acceptance **and** requires the pass verdicts | No behaviour change for review. Dropping review becomes a per-catalogue choice later |
| D13 (on-time) in P1 | D13 moves to P5, with the scheduler and deadlines | P1 stays about evidence, not clocks |

---

## 1. Boundary

```
 biz-kit (home site, TaskCore + CoopSubstrate)                    swarm executor
 ─────────────────────────────────────────────                    ──────────────
 governance: register ω (h(ω), ω and witnesses in custody) ─┐
 owner: adopt catalogue citing ω   (needs J3a facts)        │
 operator: propose τ, record pre-state digest               │  reads pending(state)
 governance: TaskDoDDefinedV2 (criteria pin ω by hash)      ├─▶ fetch ω and input from custody
 operator: agree (second key)                               │  check h(ω), run ω
 queue  ⇐ every ω-criterion has a pre verdict = fail        │  sign with executor grant
 evidence submitted → post verdicts                         │
 complete ⇐ accepted review ∧ every post verdict = pass     ◀┘  TaskOracleWitnessedV1
                                                                TaskVerdictRecordedV1

 ProofBankCore (candidates: inert, no authority) ··· proposes ω ···▶ governance registers
```

Ownership establishes accountability. Grants establish authority. **Verdicts establish evidence. TaskCore establishes closure.** The executor is an agent principal with a grant, and it can neither own a project nor close a task.

**The chapter's bank** is defined as {ω | `TaskOracleRegisteredV1` admitted ∧ not withdrawn}, a projection of the ledger. ProofBankCore may propose an ω, together with its method and source leads. Only registration admits it. No ProofBankCore seed, status or portfolio entry is an oracle fact.

---

## 2. P0 status on `main`

| v0.2 P0 item | Status | Where |
|---|---|---|
| Typed DoD from a catalogue; requester agreement with a second key | **Done** | `TaskCore.Intake`, `TaskDoDDefinedV2`, `TaskDoDAgreedV1` |
| Catalogue as a content-addressed file, adopted per project | **Done**, as YAML in custody, adopted by the project owner | `TaskIntakeCatalogueAdoptedV1` |
| Accountable owner; agents excluded | **Done** (beyond P0) | `TaskCore.Projects`, OWN-1..9 |
| Proposal and task sorts disjoint; tid minted at accept | **Partial.** A task in `proposed` without an agreed DoD plays the proposal role | Revisit only if P2 shows the conflation costs anything |
| κ constants (N_max, R_max, ε) and the scorer | **Not done** | Needed by P2 (rounds) and P5 (ε). Not by P1 |
| J0–J2, J4–J6 | **Partial.** J0/J1 hold by template instantiation; J2/J4–J6 are absent | J3 (P1) does not depend on them |
| Presence-gated requester key (R1) | **Partial.** The agreement needs a key distinct from the definer's, but not presence | Separate hardening, before P3 |

P1 can start now. Nothing it needs is missing from P0. The criteria rule in §3.1 is P1's first change.

---

## 3. P1: Executor bridge (2–3 sessions)

### 3.1 Criterion shape

```
criterion ::= {id, description}                 -- as today: review only
            | {id, description, oracle}          -- oracle = 64 lowercase hex chars = h(ω)
```

**Two rules, not one widened rule:**

| Rule | Used by | Admits |
|---|---|---|
| `validate_criteria/1` (**unchanged**) | `TaskDoDDefinedV1`, V1 evidence | exactly `{id, description}`, as today (`map_size(c) == 2`) |
| `validate_typed_criteria/1` (**new**) | `Intake.normalize_catalogue/1`, `Intake.instantiate/3`, `TaskDoDDefinedV2` | each criterion is `{id, description}` or `{id, description, oracle}`. If `oracle` is present it matches `^[0-9a-f]{64}$`. Every other V1 bound applies (1–32 unique IDs, bounded descriptions) |

`oracle` is a constant in the catalogue template. `normalize_catalogue/1` **explicitly** refuses an `oracle` that contains a `{…}` hole (`:invalid_intake_catalogue`). Refusal must not be left to the hex check by accident, because `Intake.instantiate/3` fills holes in `description` only (`intake.ex:51`). So a parameter can never select the oracle.

The criteria are already hashed into `definition_ref` (`dod.ex:493`, `host.hash(p["criteria"])`), so ω is pinned by construction (INV-D8): changing an oracle changes the definition, and that voids the agreement and every verdict.

### 3.2 Events

All are new types except where marked. Replay of existing ledgers is unchanged.

**Executor signer** := the signer's principal holds an active chapter executor grant **and**, at the event's admission, `TaskCore.Projects.kind(state, chapter, principal) == "agent"` and the principal is not offboarded. The kind is evaluated when the event is signed, not when the grant was issued.

**Slot rule** (applies to witnesses and verdicts): the first `pass` or `fail` result for a slot is final, and any later non-error result for that slot is refused (`:oracle_result_recorded`). An `error` result fills no slot, so it can be retried.

| Event | Signed by | Precondition | Effect |
|---|---|---|---|
| `TaskOracleRegisteredV1` | governance; chapter-scoped (`<chapter>/task_oracles`) | `oracle` well-formed; **ω's artifact is custody-verified under digest `oracle`**; `method ∈ {conformance, lean, quint}`; `witness_pass ≠ witness_fail`, both custody-verified digests; **h(ω) never registered in this chapter** | ω is in the chapter's bank, with its two witnesses. `source` (optional, free text) may cite a ProofBankCore candidate; it grants nothing |
| `TaskOracleWithdrawnV1` | governance; chapter-scoped | registered, not withdrawn | New adoptions may not cite ω. **Definitions already pinning it keep it.** Withdrawal is final for h(ω). A corrected ω is a new artifact with a new hash |
| `TaskExecutorGrantedV1` / `…RevokedV1` | governance; chapter-scoped | grant: principal declared kind `agent` | The key may sign witness results and verdicts in the chapter, while it remains an executor signer |
| `TaskOracleWitnessedV1` | executor signer | ω registered; `digest` is one of ω's two witnesses; `result ∈ {pass, fail, error}`; slot ⟨ω, digest⟩ free | `discriminating(ω) :⟺ rec(ω, witness_pass) = pass ∧ rec(ω, witness_fail) = fail`, where `rec` is the recorded (first non-error) result. Because slots are final, `discriminating` only changes from false to true |
| `TaskPrestateRecordedV1` | the proposing operator | τ proposed; digest custody-verified; τ not yet agreed | pre(τ) := digest. Recording it again before agreement replaces it |
| `TaskVerdictRecordedV1` | executor signer | τ's current `definition_ref`; `criterion` has `oracle = ω`; `phase = pre` ⇒ input = pre(τ); `phase = post` ⇒ input = `evidence[criterion]` of the cited current submission; slot ⟨definition_ref, criterion, phase, input⟩ free | Recorded |
| `TaskIntakeCatalogueAdoptedV1` (**changed**) | owner, as today | as today ∧ every cited ω is registered, not withdrawn, and discriminating | as today. Otherwise `:intake_oracle_not_discriminating` |
| `TaskQueuedV1` (**changed**) | operator, as today | as today ∧ for every oracle criterion, a pre verdict of `fail` on pre(τ) | as today. Otherwise `:dod_prestate_pending`, or `:dod_obligation_vacuous` if any pre verdict is `pass` (D9: restate as a regression guard) |
| `TaskCompletedV1` (**changed**) | operator, as today | as today (accepting review) ∧ for every oracle criterion, a post verdict of `pass` on the reviewed submission's evidence | as today. Otherwise `:dod_verdict_pending` / `:dod_verdict_failed` |

`pending(state)` is a pure projection over the gate. It lists the witness slots that are still free, the pre-states of proposed typed tasks without a pre verdict, and the evidence of submissions without a post verdict. The executor's whole job is `∀ e ∈ pending(state). submit(sign(eval(e)))`.

### 3.3 Decisions

- **P-DET, oracle determinism (premise).** ω is a function: `eval(ω, x)` depends only on (h(ω), x) and returns the same `pass`/`fail` on every run. `error` is the only permitted nondeterminism, for infrastructure failure. The kernel cannot check this premise. It is why first-wins slots are sound: under P-DET, arrival order between executor instances does not matter. An executor that sees two runs disagree, on any input, must report it. Governance's remedy is `TaskOracleWithdrawnV1` (R7).
- **ProofBankCore proposes; registration admits.** ProofBankCore's portfolio uses the same method vocabulary (`:conformance | :lean | :quint`), but its seeds are `inert` and confer nothing. Registration copies no ProofBankCore state. It cites the candidate in `source` at most. The executor resolves ω **only** from custody by h(ω), and refuses on a hash mismatch. There is no second, executor-side bank.
- **Chapter-scoped executor grant.** The bank and witnesses are chapter-wide, so their evaluator is too. Feed authorization gains one clause: an active executor grant reads every project feed of its chapter. This extends the chapter view `CoopSubstrate.Feed` already serves to administrators, and it is the only CoopSubstrate access change.
- **The executor must be a declared agent, at signing time.** A human key signing verdicts would be a reviewer in disguise. Review already exists and stays a separate grant. Retracting the kind, or offboarding the principal, stops new results immediately, even before the grant is revoked.
- **Pre-state is fixed by the requester, not the executor.** Otherwise the executor could pick an input that makes J3b pass.
- **No upward discharge by construction.** A verdict names its `task_id` and `definition_ref`, so a subtask's verdict cannot match a parent criterion (INV-D11).
- **Closure is monotone.** A failing post verdict on a *completed* task does not reopen it. It is refused, because the submission is no longer current. A post-close violation is evidence about the product, and P3 mints the `regression` proposal (D10).
- **Legacy is untouched.** V1 definitions keep the exact two-key rule. Typed criteria without `oracle` behave exactly as typed criteria do today.

### 3.4 Obligations (tests first, as for ownership)

| ID | Obligation | Spec |
|---|---|---|
| EXB-1 | A verdict counts only for the ω pinned in the task's current definition. Redefinition voids all verdicts | INV-D8 |
| EXB-2 | No catalogue citing a non-discriminating, unregistered or withdrawn ω is adopted | INV-D3 (J3a) |
| EXB-3 | No typed task with an oracle criterion is queued unless every pre verdict is `fail` on the requester's pre-state | INV-D3 (J3b), D9 |
| EXB-4 | No task with oracle criteria completes without a `pass` post verdict per criterion on the evidence it completes with | INV-D5 |
| EXB-5 | Only an executor signer signs witness results or verdicts: an active chapter grant, held by a principal declared `agent` and not offboarded **when the event is admitted**. Revoking the grant, retracting the kind or offboarding the principal stops new results and keeps past ones | R3 |
| EXB-6 | A subtask's verdicts never discharge its parent | INV-D11 |
| EXB-7 | Completion is monotone under trace extension | INV-D10 |
| EXB-8 | A duplicate non-error result (verdict or witness) for a filled slot is refused; `error` is retryable | replay safety |
| EXB-9 | Oracle-free and V1 tasks admit exactly the sequences they admit today | compatibility |
| EXB-9a | A `TaskDoDDefinedV1` whose criteria carry an `oracle` key is refused (`:invalid_dod_criteria`). So is a catalogue whose `oracle` contains a hole, or is not 64 lowercase hex characters | compatibility, §3.1 |
| EXB-10 | `discriminating(ω)` only changes from false to true under trace extension. A withdrawn h(ω) is never registered again | J3a stability |

Discharge follows the pattern used for ownership. A seeded random walk covers registrations, withdrawals, witness results, grants, revocations, **kind declarations and retractions, offboardings**, redefinitions, verdicts in both phases and completions. It asserts EXB-1, EXB-3, EXB-4, EXB-5, EXB-7 and EXB-10 in every admitted state, plus non-vacuity statistics. Then hand-made mutants per guard. They must include one that reads the kind at grant time, one that lets the last witness result win, and one that widens `validate_criteria/1`.

### 3.5 Swarm side (minimal)

- An executor loop: read `pending` from the chapter feeds, fetch ω and the input from custody, check h(ω) (refuse on a mismatch), evaluate, sign, and submit through `Commands`.
- ω's artifact and its witness artifacts are uploaded to biz-kit custody before ω is registered.
- Disagreement between runs (P-DET violated) is reported, never resolved by retrying until one result wins.
- **No entry-gate change in P1.** Attested-only work is P3.

### 3.6 Out of scope for P1

Deadlines and on-time (D13, moved to P5) · defeaters and renegotiation · `pro` guards beyond the J3b hint · regression minting (P3) · in-kernel native ω (deferred carve-out; revisit if P2 shows round-trip latency hurts) · κ constants · kernel-side detection of nondeterministic ω.

**Exit:** EXB-1..10 and EXB-9a green in CI at an exact head, TaskCore and SchoolOps regressions green, and one task end to end on dev: upload ω and its witnesses → register ω → witness both → adopt → propose → pre-state → define → pre fail → agree → queue → start → evidence → post pass → review → complete.

---

## P−1, P2–P5

Unchanged from v0.3, with these adjustments:

- **P−1 is still open.** Your three thawed areas have not been named yet. P2 needs them, because the shadow sample is drawn from requests in thawed areas.
- **P2:** the shadow metrics add *executor latency* (pending → verdict, p90) beside attest latency, and the **re-run disagreement rate**: a sampled second evaluation of recorded slots, which estimates how often P-DET is violated. If latency fails, that is the trigger to reconsider the native-ω carve-out.
- **P3:** adds regression minting on a post-close failing verdict (D10).
- **P5:** adds on-time adjudication by ledger receipt order and ε (D13, INV-D12).

## Risks (changes only)

- **R3 Executor key compromise** is now bounded by grant revocation and kind retraction. Both are governance-controlled and attributable. A compromised key can certify a bad ω only through witness results, and adoption still needs the owner's act. It can pass bad evidence only up to the accepting human review, which P1 retains.
- **R6 Executor liveness.** If the executor is down, typed intake stalls at queue and completion. Nothing unsafe is admitted. P2 measures it.
- **R7 Flaky ω** (new). An ω that violates P-DET can pass J3a on a lucky run and give verdicts that depend on arrival order. Mitigations: final slots make each recorded result stable and attributable; executors report disagreements; P2 samples re-runs; governance withdraws h(ω), and a corrected ω gets a new hash. Residual: verdicts recorded before withdrawal stand, and definitions already pinning ω keep it. Each such definition must be redefined by hand.

## Critical path

P−1 (now, needs your three areas) → P1 (2–3 sessions; the §3.1 criteria rule first; P0 remnants are not blocking) → P2 → P3 → P4 → P5.
