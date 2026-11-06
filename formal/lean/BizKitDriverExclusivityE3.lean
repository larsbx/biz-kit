import BizKitDriverExclusivity

/-!
E3 and its database decomposition, above the existing abstract correspondence.

Identities are immutable trusted inputs. A successful commit is atomic. In
particular, a staged cancellation/completion has not yet released occupancy.
These theorems do not establish refinement of Elixir/Ash/PostgreSQL, authorization,
lock ordering, fairness, or liveness. PostgreSQL acceptance supplies separate
implementation evidence for the modeled admission/commit boundaries.

The inherited `State.audits` counter models lifecycle status-transition events
after planning. It excludes Board.plan's separate `assignment.planned` event at
version 0; it is not a count of all persisted AuditEvent rows.
-/
namespace BizKitDriverExclusivityE3

open BizKitDispatch BizKitDriverExclusivity

/-- A partial unique index rejects X+X; a mixed-mode exclusion rejects X+C. -/
def SQLConflict (a b : Identity) : Prop :=
  a.user = b.user ∧
    ((a.exclusive = true ∧ b.exclusive = true) ∨ a.exclusive ≠ b.exclusive)

theorem exclusive_mode_decomposition (a b : Bool) :
    ((a = true ∧ b = true) ∨ a ≠ b) ↔ (a = true ∨ b = true) := by
  cases a <;> cases b <;> simp

theorem sql_conflict_iff_e3 (a b : Identity) : SQLConflict a b ↔ E3 a b := by
  unfold SQLConflict E3
  rw [exclusive_mode_decomposition]

/-- Both PostgreSQL constraints are partial on committed ACTIVE rows. -/
def ActiveSQLConflict (identities : Nat → Identity) (s : State) (i j : Nat) : Prop :=
  i ≠ j ∧ s.status i = .active ∧ s.status j = .active ∧
    SQLConflict (identities i) (identities j)

def ActiveE3Conflict (identities : Nat → Identity) (s : State) (i j : Nat) : Prop :=
  i ≠ j ∧ s.status i = .active ∧ s.status j = .active ∧
    E3 (identities i) (identities j)

theorem active_sql_conflict_iff_e3 (identities : Nat → Identity)
    (s : State) (i j : Nat) :
    ActiveSQLConflict identities s i j ↔ ActiveE3Conflict identities s i j := by
  unfold ActiveSQLConflict ActiveE3Conflict
  rw [sql_conflict_iff_e3]

/-- A trusted tenant participant is bound to exactly one global User. -/
def TrustedBinding (identities : Nat → Identity) : Prop :=
  ∀ i j, (identities i).tenant = (identities j).tenant →
    (identities i).participant = (identities j).participant →
    (identities i).user = (identities j).user

theorem e2_implies_e3 (identities : Nat → Identity) (trusted : TrustedBinding identities)
    (i j : Nat) (h : E2 (identities i) (identities j)) :
    E3 (identities i) (identities j) :=
  ⟨trusted i j h.1 h.2.1, h.2.2⟩

theorem e1_implies_e2 (a b : Identity) (h : E1 a b) : E2 a b :=
  ⟨h.1, h.2.1, Or.inl h.2.2.1⟩

theorem e3_safe_implies_e2_safe (identities : Nat → Identity)
    (trusted : TrustedBinding identities) (s : State)
    (safe : Safe (fun i j => E3 (identities i) (identities j)) s) :
    Safe (fun i j => E2 (identities i) (identities j)) s := by
  intro i j distinct hi hj conflict
  exact safe i j distinct hi hj (e2_implies_e3 identities trusted i j conflict)

theorem e3_safe_implies_e1_safe (identities : Nat → Identity)
    (trusted : TrustedBinding identities) (s : State)
    (safe : Safe (fun i j => E3 (identities i) (identities j)) s) :
    Safe (fun i j => E1 (identities i) (identities j)) s := by
  intro i j distinct hi hj conflict
  exact e3_safe_implies_e2_safe identities trusted s safe i j distinct hi hj
    (e1_implies_e2 _ _ conflict)

/-- Unlike the earlier fixed-row model, IDs begin absent and must be freshly planned. -/
structure PlanningState where
  present : Nat → Bool
  core : State

def empty : PlanningState := ⟨fun _ => false, initial⟩

def ExistingActive (s : PlanningState) : Prop :=
  ∀ i, s.core.status i = .active → s.present i = true

def freshPlan (s : PlanningState) (t : Nat) : PlanningState :=
  ⟨fun i => if i = t then true else s.present i,
    ⟨fun i => if i = t then .planned else s.core.status i,
     fun i => if i = t then 0 else s.core.version i,
     fun i => if i = t then 0 else s.core.audits i⟩⟩

theorem empty_existing_active : ExistingActive empty := by
  intro i h
  cases h

theorem fresh_plan_preserves_safety (R : Nat → Nat → Prop) (s : PlanningState)
    (t : Nat) (safe : Safe R s.core) : Safe R (freshPlan s t).core := by
  intro i j distinct hi hj
  have hi' : s.core.status i = .active := by
    by_cases hit : i = t
    · simp [freshPlan, hit] at hi
    · simpa [freshPlan, hit] using hi
  have hj' : s.core.status j = .active := by
    by_cases hjt : j = t
    · simp [freshPlan, hjt] at hj
    · simpa [freshPlan, hjt] using hj
  exact safe i j distinct hi' hj'

theorem fresh_plan_preserves_existence (s : PlanningState) (t : Nat)
    (existing : ExistingActive s) : ExistingActive (freshPlan s t) := by
  intro i hi
  by_cases hit : i = t
  · simp [freshPlan, hit]
  · have hi' : s.core.status i = .active := by simpa [freshPlan, hit] using hi
    simpa [freshPlan, hit] using existing i hi'

/-- Callers may only plan a previously absent row, with the trusted snapshot. -/
noncomputable def planAttempt (identities : Nat → Identity) (s : PlanningState)
    (t : Nat) (supplied : Identity) : Option PlanningState := by
  classical
  exact if s.present t = false ∧ supplied = identities t then some (freshPlan s t) else none

theorem accepted_plan_is_fresh (identities : Nat → Identity) (s : PlanningState)
    (t : Nat) (supplied : Identity) (out : PlanningState)
    (accepted : planAttempt identities s t supplied = some out) :
    s.present t = false ∧ supplied = identities t ∧ out = freshPlan s t := by
  classical
  unfold planAttempt at accepted
  split at accepted
  next h => exact ⟨h.1, h.2, (Option.some.inj accepted).symm⟩
  next => cases accepted

theorem accepted_plan_safe (identities : Nat → Identity) (s : PlanningState)
    (t : Nat) (supplied : Identity) (out : PlanningState)
    (safe : Safe (fun i j => E3 (identities i) (identities j)) s.core)
    (accepted : planAttempt identities s t supplied = some out) :
    Safe (fun i j => E3 (identities i) (identities j)) out.core := by
  rw [(accepted_plan_is_fresh identities s t supplied out accepted).2.2]
  exact fresh_plan_preserves_safety _ s t safe

theorem accepted_plan_preserves_existence (identities : Nat → Identity) (s : PlanningState)
    (t : Nat) (supplied : Identity) (out : PlanningState)
    (existing : ExistingActive s)
    (accepted : planAttempt identities s t supplied = some out) : ExistingActive out := by
  rw [(accepted_plan_is_fresh identities s t supplied out accepted).2.2]
  exact fresh_plan_preserves_existence s t existing

/-- Identity is outside the mutable state; a mismatching snapshot is refused. -/
def snapshotMutationAttempt (identities : Nat → Identity) (s : PlanningState)
    (t : Nat) (supplied : Identity) : Option PlanningState :=
  if supplied = identities t then some s else none

theorem changed_snapshot_refused (identities : Nat → Identity) (s : PlanningState)
    (t : Nat) (supplied : Identity) (changed : supplied ≠ identities t) :
    snapshotMutationAttempt identities s t supplied = none := by
  simp [snapshotMutationAttempt, changed]

theorem accepted_snapshot_preserves_state (identities : Nat → Identity)
    (s out : PlanningState) (t : Nat) (supplied : Identity)
    (accepted : snapshotMutationAttempt identities s t supplied = some out) :
    supplied = identities t ∧ out = s := by
  unfold snapshotMutationAttempt at accepted
  split at accepted
  next h => exact ⟨h, (Option.some.inj accepted).symm⟩
  next => cases accepted

noncomputable def activateExisting (identities : Nat → Identity) (s : PlanningState)
    (t expected : Nat) : Option PlanningState := by
  classical
  exact if s.present t = true then
    (activateAttempt (fun i j => E3 (identities i) (identities j)) s.core t expected).map
      (fun core => ⟨s.present, core⟩)
  else none

theorem absent_activation_refused (identities : Nat → Identity) (s : PlanningState)
    (t expected : Nat) (absent : s.present t = false) :
    activateExisting identities s t expected = none := by
  simp [activateExisting, absent]

theorem accepted_existing_activation_is_step (identities : Nat → Identity)
    (s out : PlanningState) (t expected : Nat)
    (accepted : activateExisting identities s t expected = some out) :
    s.present t = true ∧ out.present = s.present ∧
      out.core = commit s.core t .active ∧
      Step (fun i j => E3 (identities i) (identities j)) s.core out.core := by
  classical
  unfold activateExisting at accepted
  split at accepted
  next present =>
    unfold activateAttempt at accepted
    split at accepted
    next guard =>
      simp only [Option.map_some] at accepted
      have same : (⟨s.present, commit s.core t .active⟩ : PlanningState) = out :=
        Option.some.inj accepted
      subst out
      exact ⟨present, rfl, rfl, Step.activate s.core t guard.1 guard.2.1 guard.2.2⟩
    next => simp at accepted
  next => cases accepted

theorem accepted_existing_activation_safe (identities : Nat → Identity)
    (s out : PlanningState) (t expected : Nat)
    (safe : Safe (fun i j => E3 (identities i) (identities j)) s.core)
    (accepted : activateExisting identities s t expected = some out) :
    Safe (fun i j => E3 (identities i) (identities j)) out.core :=
  step_preserves _ s.core out.core safe
    (accepted_existing_activation_is_step identities s out t expected accepted).2.2.2

theorem accepted_existing_activation_preserves_existence (identities : Nat → Identity)
    (s out : PlanningState) (t expected : Nat) (existing : ExistingActive s)
    (accepted : activateExisting identities s t expected = some out) : ExistingActive out := by
  obtain ⟨present, samePresent, sameCore, _⟩ :=
    accepted_existing_activation_is_step identities s out t expected accepted
  intro i active
  rw [samePresent]
  by_cases selected : i = t
  · subst i
    exact present
  · rw [sameCore] at active
    exact existing i (by simpa [BizKitDriverExclusivity.commit, selected] using active)

/-- Only the two operational terminal targets can be staged. -/
inductive TerminalTarget where
  | completed
  | cancelled

def TerminalTarget.status : TerminalTarget → Status
  | .completed => .completed
  | .cancelled => .cancelled

theorem terminal_target_not_active (target : TerminalTarget) : target.status ≠ .active := by
  cases target <;> decide

def ReleaseSource (s : PlanningState) (t : Nat) : TerminalTarget → Prop
  | .completed => s.core.status t = .active
  | .cancelled => s.core.status t = .planned ∨ s.core.status t = .active

/-- A staged transaction records validated presence, source state and expected version.
Its committed state remains unchanged until commitRelease. The transaction's commit
is atomic in this model; intervening database transactions are not refined here. -/
structure PendingRelease where
  committed : PlanningState
  assignment : Nat
  target : TerminalTarget
  expected : Nat
  present : committed.present assignment = true
  sourceOpen : ReleaseSource committed assignment target
  fresh : expected = committed.core.version assignment

noncomputable def stageReleaseAttempt (s : PlanningState) (t expected : Nat)
    (target : TerminalTarget) : Option PendingRelease := by
  classical
  exact if h : s.present t = true ∧ ReleaseSource s t target ∧ expected = s.core.version t
    then some ⟨s, t, target, expected, h.1, h.2.1, h.2.2⟩ else none

def rollbackRelease (p : PendingRelease) : PlanningState := p.committed

def commitRelease (p : PendingRelease) : PlanningState :=
  ⟨p.committed.present, commit p.committed.core p.assignment p.target.status⟩

theorem accepted_staged_release_holds_occupancy (s : PlanningState) (t expected : Nat)
    (target : TerminalTarget) (p : PendingRelease)
    (accepted : stageReleaseAttempt s t expected target = some p) : p.committed = s := by
  classical
  unfold stageReleaseAttempt at accepted
  split at accepted
  next guard =>
    have same := Option.some.inj accepted
    cases same
    rfl
  next => cases accepted

theorem rollback_release_preserves_state (p : PendingRelease) :
    rollbackRelease p = p.committed := rfl

theorem committed_release_is_step (R : Nat → Nat → Prop) (p : PendingRelease) :
    Step R p.committed.core (commitRelease p).core := by
  cases p with
  | mk s t target expected present source fresh =>
    cases target with
    | completed => exact Step.complete s.core t source fresh
    | cancelled => exact Step.cancel s.core t source fresh

theorem committed_release_safe (R : Nat → Nat → Prop) (p : PendingRelease)
    (safe : Safe R p.committed.core) : Safe R (commitRelease p).core :=
  step_preserves R p.committed.core (commitRelease p).core safe (committed_release_is_step R p)

theorem committed_release_preserves_existence (p : PendingRelease)
    (existing : ExistingActive p.committed) : ExistingActive (commitRelease p) := by
  intro i active
  have selected : i ≠ p.assignment := by
    intro same
    subst i
    exact terminal_target_not_active p.target
      (by simpa [commitRelease, BizKitDriverExclusivity.commit] using active)
  exact existing i
    (by simpa [commitRelease, BizKitDriverExclusivity.commit, selected] using active)

#print axioms active_sql_conflict_iff_e3
#print axioms e3_safe_implies_e1_safe
#print axioms accepted_plan_safe
#print axioms accepted_existing_activation_safe
#print axioms accepted_existing_activation_preserves_existence
#print axioms changed_snapshot_refused
#print axioms committed_release_is_step
#print axioms committed_release_safe

end BizKitDriverExclusivityE3
