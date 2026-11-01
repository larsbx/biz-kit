import Lean

/-!
# Proof Bank pilot: InventoryCore single-location stock arithmetic

This model abstracts one location in a single merchant/item/unit aggregate.
It matches only the *quantity arithmetic* of InventoryCore.apply/3's
receive, reserve, commit and release branches (as observed at the source
revision pinned in proof_bank/characterizations/v1/catalog.json).

The host and full InventoryCore implementation include additional checks for
merchant/item/units, command IDs, optimistic versions, reservation IDs,
expiration and authorization. This theorem does **not** prove those checks,
the implementation's refinement to this model, database serialization,
multi-location transfers, baskets, or cross-service admission.

The checked property is `held ≤ onHand` for successful abstract steps.
The failed/unsafe reserve is deliberately exposed as a negative control.
-/

namespace BizKitInventory

structure Stock where
  onHand : Nat
  held : Nat
  deriving Repr, DecidableEq

def Safe (s : Stock) : Prop := s.held ≤ s.onHand

def empty : Stock := ⟨0, 0⟩

def receive (s : Stock) (q : Nat) : Stock :=
  { s with onHand := s.onHand + q }

/-- Successful reservation is permitted only for unheld capacity. -/
def reserve (s : Stock) (q : Nat) : Option Stock :=
  if q ≤ s.onHand - s.held then
    some { s with held := s.held + q }
  else none

/-- Consume an existing hold; both physical stock and held amount decrease. -/
def commit (s : Stock) (q : Nat) : Option Stock :=
  if q ≤ s.held then
    some { onHand := s.onHand - q, held := s.held - q }
  else none

/-- Remove a hold without changing on-hand stock. -/
def release (s : Stock) (q : Nat) : Option Stock :=
  if q ≤ s.held then
    some { s with held := s.held - q }
  else none

theorem empty_safe : Safe empty := by decide

theorem receive_preserves (s : Stock) (q : Nat) (hs : Safe s) :
    Safe (receive s q) := by
  dsimp [Safe, receive] at *
  omega

theorem reserve_preserves (s t : Stock) (q : Nat)
    (hs : Safe s) (success : reserve s q = some t) : Safe t := by
  unfold reserve at success
  split at success
  · cases success
    dsimp [Safe] at *
    omega
  · cases success

theorem commit_preserves (s t : Stock) (q : Nat)
    (hs : Safe s) (success : commit s q = some t) : Safe t := by
  unfold commit at success
  split at success
  · cases success
    dsimp [Safe] at *
    omega
  · cases success

theorem release_preserves (s t : Stock) (q : Nat)
    (hs : Safe s) (success : release s q = some t) : Safe t := by
  unfold release at success
  split at success
  · cases success
    dsimp [Safe] at *
    omega
  · cases success

theorem reserve_over_capacity_refused (s : Stock) (q : Nat)
    (over : s.onHand - s.held < q) : reserve s q = none := by
  have h : ¬ q ≤ s.onHand - s.held := by omega
  simp [reserve, h]

inductive Step : Stock → Stock → Prop where
  | receive (s : Stock) (q : Nat) : Step s (BizKitInventory.receive s q)
  | reserve (s t : Stock) (q : Nat) (h : BizKitInventory.reserve s q = some t) :
      Step s t
  | commit (s t : Stock) (q : Nat) (h : BizKitInventory.commit s q = some t) :
      Step s t
  | release (s t : Stock) (q : Nat) (h : BizKitInventory.release s q = some t) :
      Step s t

theorem step_preserves {s t : Stock} (h : Step s t) (hs : Safe s) :
    Safe t := by
  cases h with
  | receive s q => exact receive_preserves s q hs
  | reserve s t q success => exact reserve_preserves s t q hs success
  | commit s t q success => exact commit_preserves s t q hs success
  | release s t q success => exact release_preserves s t q hs success

inductive Reachable : Stock → Prop where
  | empty : Reachable BizKitInventory.empty
  | next {s t : Stock} (prior : Reachable s) (step : Step s t) : Reachable t

theorem reachable_safe {s : Stock} (h : Reachable s) : Safe s := by
  induction h with
  | empty => exact empty_safe
  | next _ step ih => exact step_preserves step ih

/-- Negative control: dropping the availability guard permits overselling. -/
def uncheckedReserve (s : Stock) (q : Nat) : Stock :=
  { s with held := s.held + q }

theorem unchecked_reserve_counterexample :
    ¬ Safe (uncheckedReserve ⟨1, 0⟩ 2) := by decide

/-- Representative boundary fixtures; the Elixir test exercises wider ranges. -/
example : reserve ⟨5, 0⟩ 6 = none := by decide
example : reserve ⟨5, 0⟩ 5 = some ⟨5, 5⟩ := by decide
example : commit ⟨5, 5⟩ 2 = some ⟨3, 3⟩ := by decide
example : release ⟨5, 5⟩ 5 = some ⟨5, 0⟩ := by decide

end BizKitInventory
