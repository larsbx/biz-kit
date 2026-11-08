/- Lifecycle abstraction only. This does not prove Elixir, authentication,
   clock provenance, quote provenance, persistence, or browser refinement. -/
namespace ProcurementMVP
inductive Phase where
  | requested | qualified | accepted | fulfilled | cancelled | disputed
  deriving DecidableEq, Repr

structure Binding where
  quoteId : Nat
  revision : Nat
  merchant : Nat
  amount : Nat
  deriving DecidableEq, Repr

structure State where
  phase : Phase
  version : Nat
  latest : Option Binding
  accepted : Option Binding
  evidence : Bool
  deriving DecidableEq, Repr

inductive Step : State → State → Prop where
  | qualify (s : State) (h : s.phase = .requested) :
      Step s { s with phase := .qualified, version := s.version + 1 }
  | quote (s : State) (b : Binding) (h : s.phase = .qualified) :
      Step s { s with latest := some b, version := s.version + 1 }
  | accept (s : State) (b : Binding) (h : s.phase = .qualified)
      (unbound : s.accepted = none) (exactQuote : s.latest = some b) :
      Step s { s with phase := .accepted, accepted := some b, version := s.version + 1 }
  | fulfill (s : State) (h : s.phase = .accepted) :
      Step s { s with phase := .fulfilled, version := s.version + 1 }
  | cancel (s : State) (h : s.phase = .requested ∨ s.phase = .qualified ∨ s.phase = .accepted) :
      Step s { s with phase := .cancelled, version := s.version + 1 }
  | dispute (s : State) (h : s.phase = .accepted ∨ s.phase = .fulfilled) :
      Step s { s with phase := .disputed, version := s.version + 1 }
  | recordEvidence (s : State) (b : Binding) (bound : s.accepted = some b)
      (h : s.phase = .accepted ∨ s.phase = .fulfilled ∨ s.phase = .disputed) :
      Step s { s with evidence := true, version := s.version + 1 }

def Admitted (authorized : Bool) (expected : Nat) (s t : State) : Prop :=
  authorized = true ∧ expected = s.version ∧ Step s t

theorem exact_version_increment {s t : State} (h : Step s t) :
    t.version = s.version + 1 := by cases h <;> rfl

theorem accepted_binding_immutable {s t : State} {b : Binding}
    (h : Step s t) (bound : s.accepted = some b) : t.accepted = some b := by
  cases h <;> simp_all

theorem unauthorized_not_admitted (expected : Nat) (s t : State) :
    ¬ Admitted false expected s t := by simp [Admitted]

theorem stale_not_admitted (a : Bool) (expected : Nat) (s t : State)
    (stale : expected ≠ s.version) : ¬ Admitted a expected s t := by
  simp [Admitted, stale]

theorem acceptance_does_not_create_payment (s : State) (b : Binding) :
    ({ s with phase := .accepted, accepted := some b, version := s.version + 1 } : State).evidence =
      s.evidence := rfl

#print axioms exact_version_increment
#print axioms accepted_binding_immutable
#print axioms unauthorized_not_admitted
#print axioms stale_not_admitted
#print axioms acceptance_does_not_create_payment
end ProcurementMVP
