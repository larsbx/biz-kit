import Std.Tactic

/-!
TigerBeetle outcome admission target, not a runtime or cryptographic proof.
The immutable Source is a verified complete native-history snapshot. Bodies
stand for exact canonical bytes, not a collision-free hash assumption.
One-based replay positions are NOT native transfer IDs: anchor maps them to
the retained permanent original operation ID. No financial command is modeled.
-/
namespace BizKitOutcomeAdmission

structure Origin where
  home : Nat
  cluster : Nat
  generation : Nat
  deriving DecidableEq

structure Scope where
  origin : Origin
  destination : Nat
  deriving DecidableEq

structure Slot where
  scope : Scope
  operation : Nat
  deriving DecidableEq

structure Source where
  head : Origin → Nat
  anchor : Origin → Nat → Nat
  body : Origin → Nat → Nat
  verified : Origin → Nat → Prop
  verifiedDecidable : ∀ o n, Decidable (verified o n)

instance (src : Source) (o : Origin) (n : Nat) : Decidable (src.verified o n) :=
  src.verifiedDecidable o n

def slotAt (src : Source) (scope : Scope) (n : Nat) : Slot :=
  ⟨scope, src.anchor scope.origin n⟩

def VerifiedAt (src : Source) (scope : Scope) (n body : Nat) : Prop :=
  0 < n ∧ n ≤ src.head scope.origin ∧ src.verified scope.origin n ∧
    body = src.body scope.origin n

instance (src : Source) (scope : Scope) (n body : Nat) :
    Decidable (VerifiedAt src scope n body) := by
  unfold VerifiedAt
  infer_instance

structure State where
  stored : Slot → Option Nat
  appends : Slot → Nat
  cursor : Scope → Nat

def initial : State := ⟨fun _ => none, fun _ => 0, fun _ => 0⟩

def Safe (src : Source) (s : State) : Prop :=
  (∀ k b, s.stored k = some b →
    s.appends k = 1 ∧ ∃ n, slotAt src k.scope n = k ∧ VerifiedAt src k.scope n b) ∧
  (∀ k, s.stored k = none → s.appends k = 0) ∧
  (∀ scope, s.cursor scope ≤ src.head scope.origin) ∧
  (∀ scope n, 0 < n → n ≤ s.cursor scope →
    s.stored (slotAt src scope n) = some (src.body scope.origin n))

def fresh (s : State) (k : Slot) (body : Nat) : State :=
  { s with
    stored := fun j => if j = k then some body else s.stored j
    appends := fun j => if j = k then s.appends j + 1 else s.appends j }

/-- Model of one serialized, durable Log admission and its rebuilt binding.
    A separate cursor write is deliberately NOT in this transition. -/
def admit (src : Source) (s : State) (scope : Scope) (n body : Nat) : State :=
  if VerifiedAt src scope n body ∧ s.stored (slotAt src scope n) = none
  then fresh s (slotAt src scope n) body else s

def checkpoint (src : Source) (s : State) (scope : Scope) : State :=
  let n := s.cursor scope + 1
  if VerifiedAt src scope n (src.body scope.origin n) ∧
      s.stored (slotAt src scope n) = some (src.body scope.origin n)
  then {s with cursor := fun other => if other = scope then n else s.cursor other}
  else s

/-- Crash/lost reply/restart retain the accepted Log binding, not the reply. -/
def crash (s : State) : State := s

theorem initial_safe (src : Source) : Safe src initial := by
  simp [Safe, initial]

theorem fresh_preserves (src : Source) (s : State) (scope : Scope) (n b : Nat)
    (hs : Safe src s) (hv : VerifiedAt src scope n b)
    (absent : s.stored (slotAt src scope n) = none) :
    Safe src (fresh s (slotAt src scope n) b) := by
  rcases hs with ⟨records, empty, bounds, prefix⟩
  refine ⟨?_, ?_, bounds, ?_⟩
  · intro k body stored
    by_cases hk : k = slotAt src scope n
    · subst k
      have hb : b = body := by simpa [fresh] using stored
      subst body
      exact ⟨by simpa [fresh] using congrArg (· + 1) (empty _ absent),
        n, rfl, hv⟩
    · simpa [fresh, hk] using records k body (by simpa [fresh, hk] using stored)
  · intro k missing
    by_cases hk : k = slotAt src scope n
    · simp [fresh, hk] at missing
    · simpa [fresh, hk] using empty k (by simpa [fresh, hk] using missing)
  · intro other i positive within
    have old := prefix other i positive within
    have different : slotAt src other i ≠ slotAt src scope n := by
      intro same
      rw [same, absent] at old
      contradiction
    simpa [fresh, different] using old

theorem admit_preserves (src : Source) (s : State) (scope : Scope) (n b : Nat)
    (hs : Safe src s) : Safe src (admit src s scope n b) := by
  unfold admit
  split
  · next h => exact fresh_preserves src s scope n b hs h.1 h.2
  · exact hs

theorem checkpoint_preserves (src : Source) (s : State) (scope : Scope)
    (hs : Safe src s) : Safe src (checkpoint src s scope) := by
  rcases hs with ⟨records, empty, bounds, prefix⟩
  unfold checkpoint
  split
  · next h =>
    refine ⟨records, empty, ?_, ?_⟩
    · intro other
      by_cases same : other = scope
      · subst other
        simpa using h.1.2.1
      · simpa [same] using bounds other
    · intro other n positive within
      by_cases same : other = scope
      · subst other
        have hn : n ≤ s.cursor scope + 1 := by simpa using within
        by_cases equal : n = s.cursor scope + 1
        · simpa [equal] using h.2
        · exact prefix scope n positive (by omega)
      · exact prefix other n positive (by simpa [same] using within)
  · exact ⟨records, empty, bounds, prefix⟩

theorem exact_retry_stutters (src : Source) (s : State) (scope : Scope)
    (n body original : Nat) (present : s.stored (slotAt src scope n) = some original) :
    admit src s scope n body = s := by
  simp [admit, present]

theorem changed_body_cannot_replace (src : Source) (s : State) (scope : Scope)
    (n body original : Nat) (present : s.stored (slotAt src scope n) = some original)
    (_changed : body ≠ original) : admit src s scope n body = s :=
  exact_retry_stutters src s scope n body original present

theorem unverified_stutters (src : Source) (s : State) (scope : Scope) (n b : Nat)
    (invalid : ¬ VerifiedAt src scope n b) : admit src s scope n b = s := by
  simp [admit, invalid]

theorem admission_does_not_checkpoint (src : Source) (s : State) (scope : Scope)
    (n b : Nat) (other : Scope) :
    (admit src s scope n b).cursor other = s.cursor other := by
  unfold admit
  split <;> rfl

theorem independent_destination (src : Source) (s : State) (scope other : Scope)
    (n b operation : Nat) (different : other ≠ scope) :
    (admit src s scope n b).stored ⟨other, operation⟩ = s.stored ⟨other, operation⟩ := by
  have keyDifferent : (Slot.mk other operation) ≠ slotAt src scope n := by
    intro same
    exact different (congrArg Slot.scope same)
  unfold admit
  split
  · simp [fresh, keyDifferent]
  · rfl

theorem checkpoint_does_not_append (src : Source) (s : State) (scope : Scope)
    (k : Slot) :
    (checkpoint src s scope).stored k = s.stored k ∧
    (checkpoint src s scope).appends k = s.appends k := by
  unfold checkpoint
  split <;> exact ⟨rfl, rfl⟩

theorem independent_cursor (src : Source) (s : State) (scope other : Scope)
    (different : other ≠ scope) :
    (checkpoint src s scope).cursor other = s.cursor other := by
  unfold checkpoint
  split
  · simp [different]
  · rfl

theorem missing_append_cannot_checkpoint (src : Source) (s : State) (scope : Scope)
    (missing : s.stored (slotAt src scope (s.cursor scope + 1)) = none) :
    checkpoint src s scope = s := by
  simp [checkpoint, missing]

theorem lost_reply_retry_stutters (src : Source) (s : State) (scope : Scope)
    (n b : Nat) (hv : VerifiedAt src scope n b) :
    admit src (crash (admit src s scope n b)) scope n b = admit src s scope n b := by
  by_cases present : s.stored (slotAt src scope n) = none
  · have accepted : (admit src s scope n b).stored (slotAt src scope n) = some b := by
      simp [admit, hv, present, fresh]
    exact exact_retry_stutters src _ scope n b b accepted
  · simp [admit, present, crash]

inductive Reachable (src : Source) : State → Prop where
  | init : Reachable src initial
  | append {s} : Reachable src s → (scope : Scope) → (n b : Nat) →
      Reachable src (admit src s scope n b)
  | advance {s} : Reachable src s → (scope : Scope) →
      Reachable src (checkpoint src s scope)
  | restart {s} : Reachable src s → Reachable src (crash s)

theorem reachable_safe (src : Source) {s : State} (h : Reachable src s) : Safe src s := by
  induction h with
  | init => exact initial_safe src
  | append _ scope n b ih => exact admit_preserves src _ scope n b ih
  | advance _ scope ih => exact checkpoint_preserves src _ scope ih
  | restart _ ih => exact ih

end BizKitOutcomeAdmission
