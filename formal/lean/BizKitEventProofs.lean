import Init

/-!
# EventStore consumer safety kernel

This model concerns **one home**, one committed, append-only ledger,
and the set of operational effects that have been *durably registered*.

Positions are zero-based: the ledger has entries 0 ... head-1 and
cursor is the exclusive end of the durably acknowledged prefix.
Registration is a set union; it is not an external agent launch.

What is proved:
* a cursor may advance only after the corresponding effect is present;
* appending, registering, advancing, lost notifications, and process crashes
  preserve the prefix invariant;
* registering the same effect twice has the same membership semantics;
* advancing cursor first has a concrete counterexample.

This is NOT a proof of the PostgreSQL, EventStore, Elixir runtime, network,
backend idempotency, signature verification, or liveness. Those interfaces
are separate refinement and integration obligations.
-/

namespace BizKitEventProofs

structure Consumer where
  head : Nat
  cursor : Nat
  effects : Nat → Prop

/-- Every event in the committed cursor prefix has its durable derived effect. -/
def Safe (s : Consumer) : Prop :=
  s.cursor ≤ s.head ∧ ∀ n, n < s.cursor → s.effects n

def initial : Consumer :=
  { head := 0, cursor := 0, effects := fun _ => False }

/-- The canonical EventStore appender extends the ledger, not its consumers. -/
def append (s : Consumer) : Consumer := { s with head := s.head + 1 }

/-- Durable effect registration, idempotent at the effect-ID membership level. -/
def register (s : Consumer) (n : Nat) : Consumer :=
  { s with effects := fun k => k = n ∨ s.effects k }

/-- Advance only after the just-processed event's effect is committed. -/
def acknowledge (s : Consumer) : Consumer := { s with cursor := s.cursor + 1 }

/-- Messages and process crashes cannot change committed state. -/
def wakeOrCrash (s : Consumer) : Consumer := s

theorem initial_safe : Safe initial := by
  constructor
  · rfl
  · intro n h
    exact False.elim (Nat.not_lt_zero n h)

theorem append_preserves (s : Consumer) (hs : Safe s) :
    Safe (append s) := by
  constructor
  · exact Nat.le_trans hs.1 (Nat.le_succ _)
  · exact hs.2

theorem register_preserves (s : Consumer) (n : Nat) (hs : Safe s) :
    Safe (register s n) := by
  constructor
  · exact hs.1
  · intro k hk
    exact Or.inr (hs.2 k hk)

theorem acknowledge_preserves (s : Consumer)
    (hs : Safe s) (within : s.cursor < s.head)
    (stored : s.effects s.cursor) :
    Safe (acknowledge s) := by
  constructor
  · exact Nat.succ_le_of_lt within
  · intro k hk
    have hle : k ≤ s.cursor := Nat.le_of_lt_succ hk
    rcases Nat.lt_or_eq_of_le hle with hlt | heq
    · exact hs.2 k hlt
    · simpa [heq] using stored

theorem wakeOrCrash_preserves (s : Consumer) (hs : Safe s) :
    Safe (wakeOrCrash s) := hs

/-- The abstract transition boundary: no unguarded cursor advancement. -/
inductive Step : Consumer → Consumer → Prop
  | append (s : Consumer) : Step s (BizKitEventProofs.append s)
  | register (s : Consumer) (n : Nat) (persisted : n < s.head) :
      Step s (BizKitEventProofs.register s n)
  | acknowledge (s : Consumer) (within : s.cursor < s.head)
      (stored : s.effects s.cursor) :
      Step s (BizKitEventProofs.acknowledge s)
  | wake (s : Consumer) : Step s s
  | crash (s : Consumer) : Step s s

theorem step_preserves {s t : Consumer} (step : Step s t) (hs : Safe s) :
    Safe t := by
  cases step with
  | append s => exact append_preserves s hs
  | register s n _ => exact register_preserves s n hs
  | acknowledge s within stored =>
      exact acknowledge_preserves s hs within stored
  | wake s => exact hs
  | crash s => exact hs

theorem register_idempotent (s : Consumer) (n k : Nat) :
    (register (register s n) n).effects k ↔ (register s n).effects k := by
  simp [register, or_assoc]

/-- Unsafe design: acknowledge without registration of the first event. -/
def cursorFirst (s : Consumer) : Consumer := { s with cursor := s.cursor + 1 }

theorem cursor_first_counterexample : ¬ Safe (cursorFirst initial) := by
  intro hs
  have impossible : (1 : Nat) ≤ 0 := hs.1
  exact (by decide : ¬ ((1 : Nat) ≤ 0)) impossible

end BizKitEventProofs
