import BizKitDispatch

/-! Committed-state specification only. Identity is trusted and immutable.
No SQL locks, source-role provenance, scheduling windows or refinement theorem.
All trip IDs are preallocated as planned; dynamic identity mutation is outside scope. -/
namespace BizKitDriverExclusivity
open BizKitDispatch

structure Identity where
  tenant : Nat
  participant : Nat
  user : Nat
  exclusive : Bool
  deriving DecidableEq, Repr

-- E1: the existing partial-index key and predicate.
def E1 (a b : Identity) : Prop :=
  a.tenant = b.tenant ∧ a.participant = b.participant ∧
  a.exclusive = true ∧ b.exclusive = true
-- E2: proposed mixed-profile incompatibility within one tenant participant.
def E2 (a b : Identity) : Prop :=
  a.tenant = b.tenant ∧ a.participant = b.participant ∧
  (a.exclusive = true ∨ b.exclusive = true)
-- E3: proposed cross-tenant account identity, with E2 compatibility semantics.
def E3 (a b : Identity) : Prop :=
  a.user = b.user ∧ (a.exclusive = true ∨ b.exclusive = true)

structure State where
  status : Nat → Status
  version : Nat → Nat
  audits : Nat → Nat

def initial : State := ⟨fun _ => .planned, fun _ => 0, fun _ => 0⟩
def Safe (R : Nat → Nat → Prop) (s : State) : Prop :=
  ∀ i j, i ≠ j → s.status i = .active → s.status j = .active → ¬ R i j

def Available (R : Nat → Nat → Prop) (s : State) (t : Nat) : Prop :=
  ∀ j, j ≠ t → s.status j = .active → ¬ R t j ∧ ¬ R j t

def commit (s : State) (t : Nat) (target : Status) : State :=
  ⟨fun i => if i = t then target else s.status i,
   fun i => if i = t then s.version i + 1 else s.version i,
   fun i => if i = t then s.audits i + 1 else s.audits i⟩

theorem initial_safe (R) : Safe R initial := by
  intro i j _ hi
  cases hi

theorem activate_preserves (R) (s : State) (t : Nat)
    (hs : Safe R s) (ha : Available R s t) : Safe R (commit s t .active) := by
  intro i j different hi hj
  by_cases it : i = t
  · subst i
    have jt : j ≠ t := Ne.symm different
    have oldj : s.status j = .active := by simpa [commit, jt] using hj
    exact (ha j jt oldj).1
  · by_cases jt : j = t
    · subst j
      have oldi : s.status i = .active := by simpa [commit, it] using hi
      exact (ha i it oldi).2
    · exact hs i j different (by simpa [commit, it] using hi)
        (by simpa [commit, jt] using hj)

theorem release_preserves (R) (s : State) (t : Nat) (target : Status)
    (terminal : target ≠ .active) (hs : Safe R s) : Safe R (commit s t target) := by
  intro i j different hi hj
  have it : i ≠ t := by
    intro equal
    subst i
    exact terminal (by simpa [commit] using hi)
  have jt : j ≠ t := by
    intro equal
    subst j
    exact terminal (by simpa [commit] using hj)
  exact hs i j different (by simpa [commit, it] using hi)
    (by simpa [commit, jt] using hj)

-- One abstract atomic transaction: rejection and rollback leave committed state unchanged.
inductive Step (R : Nat → Nat → Prop) : State → State → Prop where
  | activate (s t) (planned : s.status t = .planned)
      (fresh : expected = s.version t) (available : Available R s t) :
      Step R s (commit s t .active)
  | complete (s t) (active : s.status t = .active) (fresh : expected = s.version t) :
      Step R s (commit s t .completed)
  | cancel (s t) (sourceOpen : s.status t = .planned ∨ s.status t = .active)
      (fresh : expected = s.version t) : Step R s (commit s t .cancelled)
  | abort (s) : Step R s s

theorem step_preserves (R) (s s' : State) (hs : Safe R s) (h : Step R s s') :
    Safe R s' := by
  cases h with
  | activate _ t _ _ available => exact activate_preserves R s t hs available
  | complete _ t _ _ => exact release_preserves R s t .completed (by decide) hs
  | cancel _ t _ _ => exact release_preserves R s t .cancelled (by decide) hs
  | abort => exact hs

inductive Reachable (R : Nat → Nat → Prop) : State → Prop where
  | init : Reachable R initial
  | next : Reachable R s → Step R s s' → Reachable R s'

theorem reachable_safe (R) (s : State) (h : Reachable R s) : Safe R s := by
  induction h with
  | init => exact initial_safe R
  | next _ transition ih => exact step_preserves R _ _ ih transition

theorem commit_increments (s : State) (t : Nat) (target : Status) :
    (commit s t target).version t = s.version t + 1 ∧
    (commit s t target).audits t = s.audits t + 1 := by simp [commit]

theorem unrelated_unchanged (s : State) (t j : Nat) (target : Status) (h : j ≠ t) :
    (commit s t target).status j = s.status j ∧
    (commit s t target).version j = s.version j ∧
    (commit s t target).audits j = s.audits j := by simp [commit, h]

/-- An executable-shape abstract admission function; the unbounded guard uses classical choice. -/
noncomputable def activateAttempt (R : Nat → Nat → Prop) (s : State) (t expected : Nat) : Option State := by
  classical
  exact if s.status t = .planned ∧ expected = s.version t ∧ Available R s t
    then some (commit s t .active) else none

theorem stale_activation_refused (R) (s : State) (t expected : Nat)
    (stale : expected ≠ s.version t) : activateAttempt R s t expected = none := by
  classical
  simp [activateAttempt, stale]

theorem conflicting_activation_refused (R) (s : State) (t j expected : Nat)
    (different : j ≠ t) (active : s.status j = .active) (clash : R t j) :
    activateAttempt R s t expected = none := by
  classical
  have unavailable : ¬ Available R s t := by
    intro h
    exact (h j different active).1 clash
  simp [activateAttempt, unavailable]

theorem rollback_is_unchanged (R) (s : State) : Step R s s := Step.abort s

-- Explicit finite counterexamples: E1 is weaker than E2 and E3.
def driver : Identity := ⟨0, 0, 7, true⟩
def mixed : Identity := ⟨0, 0, 7, false⟩
def foreign : Identity := ⟨1, 1, 7, true⟩
theorem partial_index_misses_mixed : ¬ E1 driver mixed ∧ E2 driver mixed := by simp [E1, E2, driver, mixed]
theorem tenant_key_misses_shared_user : ¬ E1 driver foreign ∧ E3 driver foreign := by simp [E1, E3, driver, foreign]

-- A stale snapshot can admit both individually, then two unchecked commits violate safety.
def sameDriver (_ : Nat) : Identity := driver
def conflict (i j : Nat) : Prop := E1 (sameDriver i) (sameDriver j)
theorem snapshot_initially_available : Available conflict initial 0 ∧ Available conflict initial 1 := by
  constructor <;> intro j _ hj <;> cases hj

theorem unchecked_competing_commits_unsafe :
    ¬ Safe conflict (commit (commit initial 0 .active) 1 .active) := by
  intro h
  have bad := h 0 1 (by decide) (by simp [commit]) (by simp [commit])
  exact bad (by simp [conflict, sameDriver, E1, driver])

#print axioms stale_activation_refused
#print axioms conflicting_activation_refused
#print axioms reachable_safe
#print axioms unchecked_competing_commits_unsafe
end BizKitDriverExclusivity
