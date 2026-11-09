import Std

/-!
# Commercial clearing business-source lineage: original-only irreversibility

This is a pure state-machine abstraction of CoopSubstrate's *read projection*.
It proves that an original-only source cannot be regained after assignment,
discharge, or legacy netting. No invoices, corporate authority, bank funds,
jurisdiction decision, signatures or effective contractual release are proved.

This model does NOT prove that the Elixir projection refines it. The runtime
acceptance tests must compare actual canonical Log replay and source lineages.
-/

namespace BizKitCommercialLineage

inductive Change where
  | assignment
  | directDischarge
  | legacyNetting
  | observe
  deriving DecidableEq, Repr

structure SourceState where
  originalOnly : Bool
  open : Bool
  revision : Nat
  deriving Repr

def recorded : SourceState :=
  ⟨true, true, 1⟩

def change (s : SourceState) : Change → SourceState
  | .assignment =>
      { s with originalOnly := false, revision := s.revision + 1 }
  | .directDischarge =>
      { s with originalOnly := false, open := false, revision := s.revision + 1 }
  | .legacyNetting =>
      { s with originalOnly := false, open := false, revision := s.revision + 1 }
  | .observe => s

def replay (s : SourceState) : List Change → SourceState
  | [] => s
  | operation :: rest => replay (change s operation) rest

theorem recorded_is_original :
    recorded.originalOnly = true ∧ recorded.open = true ∧ recorded.revision = 1 := by
  decide

theorem assignment_invalidates_original (s : SourceState) :
    (change s .assignment).originalOnly = false := rfl

theorem direct_discharge_invalidates_original (s : SourceState) :
    (change s .directDischarge).originalOnly = false ∧
    (change s .directDischarge).open = false := by
  decide

theorem legacy_netting_invalidates_original (s : SourceState) :
    (change s .legacyNetting).originalOnly = false ∧
    (change s .legacyNetting).open = false := by
  decide

/-- No further operation can restore the classification after it has gone. -/
theorem change_cannot_regain_original (s : SourceState) (a : Change)
    (h : s.originalOnly = false) :
    (change s a).originalOnly = false := by
  cases a <;> simp [change, h]

/-- Uniform finite-history result, not merely one fixture. -/
theorem replay_cannot_regain_original (s : SourceState) (operations : List Change)
    (h : s.originalOnly = false) :
    (replay s operations).originalOnly = false := by
  induction operations generalizing s with
  | nil =>
      simpa [replay] using h
  | cons a tail ih =>
      simpa [replay] using
        ih (change s a) (change_cannot_regain_original s a h)

/-- Assigning away, then back, never manufactures a new original claim. -/
theorem assign_out_and_back_not_original (s : SourceState) :
    (change (change s .assignment) .assignment).originalOnly = false := rfl

/-- The lineage version never decreases on any represented transition. -/
theorem change_revision_monotone (s : SourceState) (a : Change) :
    s.revision ≤ (change s a).revision := by
  cases a <;> simp [change]

theorem replay_revision_monotone (s : SourceState) (operations : List Change) :
    s.revision ≤ (replay s operations).revision := by
  induction operations generalizing s with
  | nil => simp [replay]
  | cons a tail ih =>
      apply Nat.le_trans (change_revision_monotone s a)
      simpa [replay] using ih (change s a)

/-- A direct discharge and all its successors remain closed. -/
theorem change_preserves_closed (s : SourceState) (a : Change)
    (h : s.open = false) :
    (change s a).open = false := by
  cases a <;> simp [change, h]

theorem replay_preserves_closed (s : SourceState) (operations : List Change)
    (h : s.open = false) :
    (replay s operations).open = false := by
  induction operations generalizing s with
  | nil => simpa [replay] using h
  | cons a tail ih =>
      simpa [replay] using ih (change s a) (change_preserves_closed s a h)

end BizKitCommercialLineage
