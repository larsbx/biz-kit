# Dispatch exclusivity: Lean and Quint verification layer

This is a specification/testbank for issue #296, added to draft PR #312.
It changes no assignment writer, database constraint or operational policy.
E2 and E3 remain proposed requirements. Formal model results do not establish
Elixir/Ash/PostgreSQL refinement or imply that a database enforces these guards.

## Lean: arbitrary trip IDs and a fixed identity relation

`formal/lean/BizKitDriverExclusivity.lean` imports the existing Dispatch status
constructors while keeping its global state separate from the individual-trip
model. State consists of status, version and abstract audit count functions on
natural-number trip IDs. All IDs are preallocated in PLANNED state. Identity
metadata is trusted and immutable, supplied through a fixed relation `R i j`.
For any identity function `id`, instantiate that relation with:

| Requirement | Incompatible pair relation |
| --- | --- |
| E1: current index scope | `E1 (id i) (id j)`: same tenant and participant; both exclusive |
| E2: proposed mixed-profile rule | `E2 (id i) (id j)`: same tenant and participant; either exclusive |
| E3: proposed cross-tenant rule | `E3 (id i) (id j)`: same global User account; either exclusive |

`Safe R s` forbids distinct ACTIVE trips related by `R`. `Available R s t`
checks both relation orientations against every other ACTIVE trip.

Theorems include:

- `initial_safe`, `activate_preserves`, `release_preserves`,
  `step_preserves`, `reachable_safe`: an atomic commit protocol preserves
  global exclusivity for every fixed incompatibility relation. This is an
  unbounded induction on abstract committed transitions, not bounded sampling.
- `commit_increments`, `unrelated_unchanged`: selected-trip version/audit
  increments and preservation of the other trips' fields.
- `stale_activation_refused`, `conflicting_activation_refused`: the abstract
  activation admission function refuses stale versions and conflicting ACTIVE
  trips. Its unbounded availability test is classical/noncomputable; it is not
  an implementation of a database query.
- `rollback_is_unchanged`: abort is identity on the committed state.
- `partial_index_misses_mixed`, `tenant_key_misses_shared_user`: concrete
  identities distinguish E1 from each stronger rule.
- `snapshot_initially_available`, `unchecked_competing_commits_unsafe`:
  two trips can both pass admission against the initial snapshot, while two
  subsequent unchecked commits violate exclusivity.

The source-state guards admit activation from PLANNED, completion from ACTIVE,
and cancellation from PLANNED or ACTIVE. A successful abstract transition is
one atomic committed change. Aborts include refusals and rollback; there is no
proof of lock acquisition, isolation level, progress or deadlock freedom.

## Quint: finite transactions and explicit regression traces

`formal/quint/dispatch_exclusivity.qnt` has two trip IDs, three selectable
policies and four identity/profile scenarios: same exclusive participant,
mixed exclusive/concurrent profiles, shared account across tenants, and two
concurrent profiles. Versions and abstract audit counts are recorded per trip.

Begin stages a trip and captures its version without changing committed
status. Safe activation rechecks the selected incompatibility rule and version
at commit. Completion/cancellation release the active slot. A pending operation
can roll back; cancellation after begin supplies a stale-version refusal case.
Identity metadata remains fixed. These are atomic model actions, not models of
PostgreSQL's internal lock manager or uncommitted index tuples.

Nine directed tests cover competing commits, rollback, completion/cancellation
slot release, stale versions, permitted concurrent profiles, mixed-profile and
cross-tenant scope counterexamples, and the unchecked snapshot race. Safe
sampling checks `safety` (selected exclusivity plus audit/version equality).
Apalache checks the same invariant to depth 8 over this finite identity domain;
that is bounded evidence, not an unbounded temporal proof.

Two deliberately weaker step relations must be refuted by actual invariant
violations: `snapshotStep/safety` omits commit-time availability revalidation;
`tenantStep/globalSafety` uses only E1 while testing E3. The deterministic
counterexample tests also pin mixed-profile and cross-tenant limitations
separately. Two explicitly concurrent profiles remain permitted under E3.

## Reproduction and evidence boundaries

Use the repository's SHA-256-checked Lean 4.35.0 installation and Quint 0.32.0
(default Apalache 0.56.1). From repository root:

```sh
git rev-parse HEAD
cd formal/lean
lake build BizKitDriverExclusivity
lake env leanchecker --fresh BizKitDriverExclusivity
cd ../..
bash formal/quint/check_dispatch_exclusivity.sh
```

The default `formal/lean/check.sh` now also builds and freshly kernel-replays
this module and audits its defining module with the existing pinned axiom-audit
allowlist (`propext`, `Classical.choice`, `Quot.sound`). The default Quint check
script includes the focused testbank. No imported project proof was reused as
a substitute for checking the new source. See the companion JSON receipt for
local results; exact-head hosted acceptance is a separate outstanding check.

The local environment required a process-path compatibility shim: Lean's
lookup of `/proc/<own-pid>/exe` failed, while `/proc/self/exe` resolved correctly.
The shim redirects only that self-executable lookup; it does not alter Lean
proof terms, imports or kernel checks. Release archive bytes were verified by
the committed installer. Re-run without the shim on an ordinary server/CI host.
Rust evaluator and Apalache archives were extracted without changing archive
ownership because this container cannot adopt the archive owners.

Trusted assumptions still include correct user/participant binding, authority
admission, fixed profile semantics, atomic mutation/audit commits, correct
assignment-writer coverage, deployed database constraints and protection from
privileged predicate/identity mutation. No theorem here proves those runtime
assumptions. Duplicate accounts for one human, planned time-window scheduling,
identity changes/re-enrolment during a trip, consent lifetimes and cross-system
assignments require additional specification and evidence. Keep #296 open.
