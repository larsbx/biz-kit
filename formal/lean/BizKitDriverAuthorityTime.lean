import BizKitDriverExclusivity

/-!
Temporal authority for one activation (issue #296), above the abstract
exclusivity specification.

An activation has three instants: `admitted` (authority read after the
transaction's locks), `checked` (an optional re-read after its waits) and
`committed`. Authority is a predicate on instants. The four policies below are
the candidates for which instants must satisfy it. This file orders them and
separates them with counterexamples; it does not select one.

`Frozen` is the premise that a row lock supplies for database-recorded
authority: the recorded answer cannot change between admission and commit.
Nothing supplies it for a wall clock or for a session held in another store.

Instants are abstract naturals on one clock. Clock skew between the
application and the database, the duration of the commit itself, and the
refinement of Elixir/Ash/PostgreSQL are outside these theorems, as are
liveness, fairness and lock ordering.
-/
namespace BizKitDriverAuthorityTime

open BizKitDispatch BizKitDriverExclusivity

structure Activation where
  admitted : Nat
  checked : Nat
  committed : Nat
  admitted_le_checked : admitted ≤ checked
  checked_le_committed : checked ≤ committed

inductive Policy where
  /-- Authority at transaction admission only. -/
  | admission
  /-- Admission, and a commit no later than `wait` after it. -/
  | bounded (wait : Nat)
  /-- Admission, and again at a re-read that precedes the commit. -/
  | recheck
  /-- Admission, and again at the commit instant itself. -/
  | commit

def Policy.Accepts (valid : Nat → Prop) (x : Activation) : Policy → Prop
  | .admission => valid x.admitted
  | .bounded wait => valid x.admitted ∧ x.committed ≤ x.admitted + wait
  | .recheck => valid x.admitted ∧ valid x.checked
  | .commit => valid x.admitted ∧ valid x.committed

/-- Authority that holds at two instants holds between them. -/
def Convex (valid : Nat → Prop) : Prop :=
  ∀ a b c, a ≤ b → b ≤ c → valid a → valid c → valid b

/-- A grant, token or session lifetime: in force from `starts` until `ends`. -/
def Within (starts ends : Nat) : Nat → Prop := fun τ => starts ≤ τ ∧ τ < ends

theorem within_convex (starts ends : Nat) : Convex (Within starts ends) := by
  intro a b c ab bc ha hc
  exact ⟨Nat.le_trans ha.1 ab, Nat.lt_of_le_of_lt bc hc.2⟩

theorem and_convex (p q : Nat → Prop) (hp : Convex p) (hq : Convex q) :
    Convex (fun τ => p τ ∧ q τ) := by
  intro a b c ab bc ha hc
  exact ⟨hp a b c ab bc ha.1 hc.1, hq a b c ab bc ha.2 hc.2⟩

/-! The order between the candidates. -/

theorem bounded_accepts_admission (valid : Nat → Prop) (x : Activation) (wait : Nat)
    (h : (Policy.bounded wait).Accepts valid x) : Policy.admission.Accepts valid x := h.1

theorem recheck_accepts_admission (valid : Nat → Prop) (x : Activation)
    (h : Policy.recheck.Accepts valid x) : Policy.admission.Accepts valid x := h.1

theorem commit_accepts_recheck (valid : Nat → Prop) (convex : Convex valid) (x : Activation)
    (h : Policy.commit.Accepts valid x) : Policy.recheck.Accepts valid x :=
  ⟨h.1, convex _ _ _ x.admitted_le_checked x.checked_le_committed h.1 h.2⟩

/-- A zero wait leaves no instant between admission and commit. -/
theorem bounded_zero_accepts_commit (valid : Nat → Prop) (x : Activation)
    (h : (Policy.bounded 0).Accepts valid x) : Policy.commit.Accepts valid x := by
  have same : x.committed = x.admitted :=
    Nat.le_antisymm h.2 (Nat.le_trans x.admitted_le_checked x.checked_le_committed)
  exact ⟨h.1, same ▸ h.1⟩

/-- Under a bounded wait, a lifetime has ended at most `wait` before the commit. -/
theorem bounded_lapse (starts ends wait : Nat) (x : Activation)
    (h : (Policy.bounded wait).Accepts (Within starts ends) x) : x.committed < ends + wait :=
  Nat.lt_of_le_of_lt h.2 (Nat.add_lt_add_right h.1.2 wait)

/-! The candidates are distinct: one activation that waited separates them. -/

def waited : Activation := ⟨0, 1, 2, by decide, by decide⟩

theorem admission_not_recheck :
    Policy.admission.Accepts (Within 0 1) waited ∧ ¬ Policy.recheck.Accepts (Within 0 1) waited := by
  simp [Policy.Accepts, Within, waited]

theorem recheck_not_commit :
    Policy.recheck.Accepts (Within 0 2) waited ∧ ¬ Policy.commit.Accepts (Within 0 2) waited := by
  simp [Policy.Accepts, Within, waited]

theorem bounded_not_commit :
    (Policy.bounded 2).Accepts (Within 0 1) waited ∧
      ¬ Policy.commit.Accepts (Within 0 1) waited := by
  simp [Policy.Accepts, Within, waited]

theorem commit_not_bounded :
    Policy.commit.Accepts (Within 0 3) waited ∧
      ¬ (Policy.bounded 1).Accepts (Within 0 3) waited := by
  simp [Policy.Accepts, Within, waited]

/-! What a held row lock contributes, and what it cannot. -/

/-- The recorded answer does not change from admission through commit. -/
def Frozen (recorded : Nat → Prop) (x : Activation) : Prop :=
  ∀ τ, x.admitted ≤ τ → τ ≤ x.committed → (recorded τ ↔ recorded x.admitted)

theorem frozen_admission_iff_commit (recorded : Nat → Prop) (x : Activation)
    (frozen : Frozen recorded x) :
    Policy.admission.Accepts recorded x ↔ Policy.commit.Accepts recorded x := by
  have last := frozen x.committed
    (Nat.le_trans x.admitted_le_checked x.checked_le_committed) (Nat.le_refl _)
  exact ⟨fun h => ⟨h, last.mpr h⟩, fun h => h.1⟩

/-- With recorded authority frozen, commit-time authority reduces to one further
read of the unfrozen part at the commit instant. -/
theorem commit_reduces_to_unfrozen (recorded unfrozen : Nat → Prop) (x : Activation)
    (frozen : Frozen recorded x) :
    Policy.commit.Accepts (fun τ => recorded τ ∧ unfrozen τ) x ↔
      Policy.admission.Accepts (fun τ => recorded τ ∧ unfrozen τ) x ∧ unfrozen x.committed := by
  have last := frozen x.committed
    (Nat.le_trans x.admitted_le_checked x.checked_le_committed) (Nat.le_refl _)
  exact ⟨fun h => ⟨h.1, h.2.2⟩, fun h => ⟨h.1, last.mpr h.1.1, h.2⟩⟩

/-- A lifetime is not frozen by any lock: it ends on its own. -/
theorem lifetime_not_frozen : ¬ Frozen (Within 0 1) waited := by
  intro frozen
  have h := (frozen 2 (by decide) (by decide)).mpr (by simp [Within, waited])
  simp [Within] at h

/-! No candidate weakens occupancy: a policy only refuses more activations. -/

noncomputable def guardedActivation (R : Nat → Nat → Prop) (accepted : Prop) (s : State)
    (t expected : Nat) : Option State := by
  classical
  exact if accepted then activateAttempt R s t expected else none

theorem refused_authority_commits_nothing (R : Nat → Nat → Prop) (accepted : Prop) (s : State)
    (t expected : Nat) (refused : ¬ accepted) :
    guardedActivation R accepted s t expected = none := by
  simp [guardedActivation, refused]

theorem guarded_activation_is_step (R : Nat → Nat → Prop) (accepted : Prop) (s result : State)
    (t expected : Nat) (committed : guardedActivation R accepted s t expected = some result) :
    accepted ∧ Step R s result := by
  classical
  unfold guardedActivation at committed
  split at committed
  next holds => exact ⟨holds, accepted_activation_is_step R s result t expected committed⟩
  next => cases committed

theorem guarded_activation_safe (R : Nat → Nat → Prop) (accepted : Prop) (s result : State)
    (t expected : Nat) (safe : Safe R s)
    (committed : guardedActivation R accepted s t expected = some result) : Safe R result :=
  step_preserves R s result safe
    (guarded_activation_is_step R accepted s result t expected committed).2

/-- Every committed activation satisfied the governing policy, whichever is chosen. -/
theorem committed_activation_was_authorized (R : Nat → Nat → Prop) (p : Policy)
    (valid : Nat → Prop) (x : Activation) (s result : State) (t expected : Nat)
    (committed : guardedActivation R (p.Accepts valid x) s t expected = some result) :
    p.Accepts valid x :=
  (guarded_activation_is_step R _ s result t expected committed).1

#print axioms commit_accepts_recheck
#print axioms bounded_zero_accepts_commit
#print axioms bounded_lapse
#print axioms admission_not_recheck
#print axioms recheck_not_commit
#print axioms commit_not_bounded
#print axioms frozen_admission_iff_commit
#print axioms commit_reduces_to_unfrozen
#print axioms lifetime_not_frozen
#print axioms guarded_activation_safe
#print axioms committed_activation_was_authorized

end BizKitDriverAuthorityTime
