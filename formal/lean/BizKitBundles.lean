import Init

/-!
# Multiple-effects and processed-no-op safety contract

One accepted EventStore position may derive zero, one, or multiple operational
effect IDs. It is unsafe to checkpoint when only *some* effects are stored.
A no-effect position must still receive a durable processed receipt.

The required-effect relation is trusted, immutable event derivation from an
already authenticated canonical ledger; this module does not verify signatures
or implement the derivation. None of the proofs assert SQL transactionality.
-/

namespace BizKitEventProofs

structure BundleConsumer where
  head : Nat
  cursor : Nat
  required : Nat → Nat → Prop
  registered : Nat → Nat → Prop
  receipts : Nat → Prop

/-- Completion means an explicit durable processed receipt AND all effects. -/
def BundleReady (s : BundleConsumer) (n : Nat) : Prop :=
  s.receipts n ∧ ∀ effect, s.required n effect → s.registered n effect

def BundleSafe (s : BundleConsumer) : Prop :=
  s.cursor ≤ s.head ∧ ∀ n, n < s.cursor → BundleReady s n

def emptyBundles : BundleConsumer :=
  { head := 0
    cursor := 0
    required := fun _ _ => False
    registered := fun _ _ => False
    receipts := fun _ => False }

def appendBundle (s : BundleConsumer) : BundleConsumer :=
  { s with head := s.head + 1 }

def registerBundleEffect (s : BundleConsumer) (n effect : Nat) : BundleConsumer :=
  { s with registered := fun i e => (i = n ∧ e = effect) ∨ s.registered i e }

def markProcessed (s : BundleConsumer) (n : Nat) : BundleConsumer :=
  { s with receipts := fun k => k = n ∨ s.receipts k }

def advanceBundle (s : BundleConsumer) : BundleConsumer :=
  { s with cursor := s.cursor + 1 }

theorem emptyBundles_safe : BundleSafe emptyBundles := by
  constructor
  · rfl
  · intro n h
    exact False.elim (Nat.not_lt_zero n h)

theorem appendBundle_preserves (s : BundleConsumer) (hs : BundleSafe s) :
    BundleSafe (appendBundle s) := by
  constructor
  · exact Nat.le_trans hs.1 (Nat.le_succ _)
  · exact hs.2

theorem registerBundleEffect_preserves
    (s : BundleConsumer) (n effect : Nat) (hs : BundleSafe s) :
    BundleSafe (registerBundleEffect s n effect) := by
  constructor
  · exact hs.1
  · intro k hk
    obtain ⟨receipt, complete⟩ := hs.2 k hk
    constructor
    · exact receipt
    · intro e he
      exact Or.inr (complete e he)

theorem markProcessed_preserves (s : BundleConsumer) (n : Nat)
    (hs : BundleSafe s) : BundleSafe (markProcessed s n) := by
  constructor
  · exact hs.1
  · intro k hk
    obtain ⟨receipt, complete⟩ := hs.2 k hk
    exact ⟨Or.inr receipt, complete⟩

theorem advanceBundle_preserves (s : BundleConsumer)
    (hs : BundleSafe s) (within : s.cursor < s.head)
    (ready : BundleReady s s.cursor) :
    BundleSafe (advanceBundle s) := by
  constructor
  · exact Nat.succ_le_of_lt within
  · intro k hk
    have hle : k ≤ s.cursor := Nat.le_of_lt_succ hk
    rcases Nat.lt_or_eq_of_le hle with hlt | heq
    · exact hs.2 k hlt
    · simpa [heq] using ready

/-- Vacuous zero-effect completeness does NOT substitute for a receipt. -/
theorem no_effect_position_requires_receipt (s : BundleConsumer) (n : Nat)
    (missing : ¬ s.receipts n) : ¬ BundleReady s n := by
  intro ready
  exact missing ready.1

/-- Processing an event with two effects cannot skip the second effect. -/
theorem partial_bundle_cannot_advance
    (s : BundleConsumer) (n missingEffect : Nat)
    (required : s.required n missingEffect)
    (absent : ¬ s.registered n missingEffect) :
    ¬ BundleReady s n := by
  intro ready
  exact absent (ready.2 missingEffect required)

end BizKitEventProofs
