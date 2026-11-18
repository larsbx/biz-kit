import Std

namespace ResearchExchange

/-- Abstract identities for the four commitments checked by a verifier.
    Equality models an exact authenticated commitment comparison, not cryptography. -/
structure Binding where
  target : Nat
  input : Nat
  environment : Nat
  policy : Nat
  deriving DecidableEq, BEq, Repr

structure Candidate where
  worker : Nat
  generation : Nat
  binding : Binding
  artifact : Nat
  submittedAt : Nat
  leaseExpires : Nat
  deriving DecidableEq, BEq, Repr

theorem binding_eq_iff (a b : Binding) :
    a = b ↔ a.target = b.target ∧ a.input = b.input ∧
      a.environment = b.environment ∧ a.policy = b.policy := by
  constructor
  · intro h
    subst b
    simp
  · cases a
    cases b
    simp only [Binding.mk.injEq]
    intro h
    exact h

end ResearchExchange
