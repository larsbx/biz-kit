import Std

/-!
# Commercial clearing source-bound admission: two-source atomic reference

A universal theorem over a *two-source* business-admission transition.
The source identifiers include the chapter; they are not amounts, and a
revised source never gets a fresh identity. No signature, legal authority,
bank transfer, runtime refinement or cross-node commit is proved here.

`evidenceOK` is an EXTERNAL premise supplied by the model. It must never
be taken from an untrusted application caller. The existing aggregate-only
NettingExecuted event is not proven source-bound by these theorems.
-/

namespace BizKitCommercialSetoff

abbrev SourceKey := Nat × Nat
abbrev IntentKey := Nat × Nat

structure State where
  consumed : SourceKey → Bool
  intents : IntentKey → Bool
  commits : Nat

def initial : State :=
  ⟨fun _ => false, fun _ => false, 0⟩

/-- Exactly two distinct original claims, current evidence, fresh intent,
    and neither source already consumed are necessary for admission. -/
def Ready (s : State) (intent : IntentKey) (a b : SourceKey)
    (evidenceOK : Bool) : Prop :=
  evidenceOK = true ∧ a ≠ b ∧
    s.consumed a = false ∧ s.consumed b = false ∧
    s.intents intent = false

/-- Computable Boolean membership and equality decide this proposed gate.
    Necessary for the `if Ready ...` admission transition to elaborate. -/
instance (s : State) (intent : IntentKey) (a b : SourceKey)
    (evidenceOK : Bool) : Decidable (Ready s intent a b evidenceOK) := by
  unfold Ready
  infer_instance

/-- Ideal atomic business admission; not the runtime Log implementation. -/
def admit (s : State) (intent : IntentKey) (a b : SourceKey)
    (evidenceOK : Bool) : State :=
  if Ready s intent a b evidenceOK then
    { consumed := fun key => if key = a ∨ key = b then true else s.consumed key
      intents := fun key => if key = intent then true else s.intents key
      commits := s.commits + 1 }
  else s

theorem initial_no_commits : initial.commits = 0 := rfl
theorem initial_no_sources (a : SourceKey) : initial.consumed a = false := rfl
theorem initial_no_intents (intent : IntentKey) : initial.intents intent = false := rfl

theorem failed_evidence_stutters (s : State) (intent : IntentKey)
    (a b : SourceKey) : admit s intent a b false = s := by
  have hn : ¬ Ready s intent a b false := by
    simp [Ready]
  simp [admit, hn]

theorem same_source_stutters (s : State) (intent : IntentKey)
    (a : SourceKey) (evidenceOK : Bool) :
    admit s intent a a evidenceOK = s := by
  have hn : ¬ Ready s intent a a evidenceOK := by
    simp [Ready]
  simp [admit, hn]

theorem rejected_stutters (s : State) (intent : IntentKey)
    (a b : SourceKey) (evidenceOK : Bool)
    (h : ¬ Ready s intent a b evidenceOK) :
    admit s intent a b evidenceOK = s := by
  simp [admit, h]

theorem accepted_marks_first (s : State) (intent : IntentKey)
    (a b : SourceKey) (evidenceOK : Bool)
    (h : Ready s intent a b evidenceOK) :
    (admit s intent a b evidenceOK).consumed a = true := by
  simp [admit, h]

theorem accepted_marks_second (s : State) (intent : IntentKey)
    (a b : SourceKey) (evidenceOK : Bool)
    (h : Ready s intent a b evidenceOK) :
    (admit s intent a b evidenceOK).consumed b = true := by
  simp [admit, h]

theorem accepted_marks_intent (s : State) (intent : IntentKey)
    (a b : SourceKey) (evidenceOK : Bool)
    (h : Ready s intent a b evidenceOK) :
    (admit s intent a b evidenceOK).intents intent = true := by
  simp [admit, h]

theorem accepted_increments_once (s : State) (intent : IntentKey)
    (a b : SourceKey) (evidenceOK : Bool)
    (h : Ready s intent a b evidenceOK) :
    (admit s intent a b evidenceOK).commits = s.commits + 1 := by
  simp [admit, h]

theorem already_consumed_first_stutters (s : State) (intent : IntentKey)
    (a b : SourceKey) (evidenceOK : Bool)
    (hused : s.consumed a = true) :
    admit s intent a b evidenceOK = s := by
  have hn : ¬ Ready s intent a b evidenceOK := by
    intro hr
    have absent : s.consumed a = false := hr.2.2.1
    rw [hused] at absent
    contradiction
  exact rejected_stutters s intent a b evidenceOK hn

theorem already_consumed_second_stutters (s : State) (intent : IntentKey)
    (a b : SourceKey) (evidenceOK : Bool)
    (hused : s.consumed b = true) :
    admit s intent a b evidenceOK = s := by
  have hn : ¬ Ready s intent a b evidenceOK := by
    intro hr
    have absent : s.consumed b = false := hr.2.2.2.1
    rw [hused] at absent
    contradiction
  exact rejected_stutters s intent a b evidenceOK hn

theorem already_seen_intent_stutters (s : State) (intent : IntentKey)
    (a b : SourceKey) (evidenceOK : Bool)
    (hused : s.intents intent = true) :
    admit s intent a b evidenceOK = s := by
  have hn : ¬ Ready s intent a b evidenceOK := by
    intro hr
    have absent : s.intents intent = false := hr.2.2.2.2
    rw [hused] at absent
    contradiction
  exact rejected_stutters s intent a b evidenceOK hn

theorem exact_retry_stutters (s : State) (intent : IntentKey)
    (a b : SourceKey) (evidenceOK : Bool)
    (h : Ready s intent a b evidenceOK) :
    admit (admit s intent a b evidenceOK) intent a b evidenceOK =
      admit s intent a b evidenceOK := by
  exact already_seen_intent_stutters _ intent a b evidenceOK
    (accepted_marks_intent s intent a b evidenceOK h)

theorem competing_first_source_stutters (s : State) (intent next : IntentKey)
    (a b c : SourceKey) (evidenceOK nextEvidenceOK : Bool)
    (h : Ready s intent a b evidenceOK) :
    admit (admit s intent a b evidenceOK) next a c nextEvidenceOK =
      admit s intent a b evidenceOK := by
  exact already_consumed_first_stutters _ next a c nextEvidenceOK
    (accepted_marks_first s intent a b evidenceOK h)

/-- Same-sized debts with changed source IDs remain different business claims. -/
theorem source_substitution_is_distinct :
    ((0, 2) : SourceKey) ≠ ((0, 3) : SourceKey) := by
  decide

theorem chapter_is_in_source_identity :
    ((0, 7) : SourceKey) ≠ ((1, 7) : SourceKey) := by
  decide

/-! The review gate accepts a bounded list at runtime. The model below proves
the reservation rule for arbitrary finite lists. Evidence freshness and exact
signed-term equality are Boolean premises supplied by the admission boundary. -/

def reviewReady (s : State) (intent : IntentKey) (sources : List SourceKey)
    (profile evidenceCurrent exactTerms : Bool) : Bool :=
  profile && evidenceCurrent && exactTerms && !s.intents intent &&
    sources.all (fun key => !s.consumed key)

def reserveReview (s : State) (intent : IntentKey) (sources : List SourceKey)
    (profile evidenceCurrent exactTerms : Bool) : State :=
  if reviewReady s intent sources profile evidenceCurrent exactTerms then
    { consumed := fun key => sources.contains key || s.consumed key
      intents := fun key => key == intent || s.intents key
      commits := s.commits + 1 }
  else s

theorem review_refuses_stale_evidence (s : State) (intent : IntentKey)
    (sources : List SourceKey) (profile exactTerms : Bool) :
    reserveReview s intent sources profile false exactTerms = s := by
  simp [reserveReview, reviewReady]

theorem review_refuses_changed_terms (s : State) (intent : IntentKey)
    (sources : List SourceKey) (profile evidenceCurrent : Bool) :
    reserveReview s intent sources profile evidenceCurrent false = s := by
  simp [reserveReview, reviewReady]

theorem review_reserves_every_source (s : State) (intent : IntentKey)
    (sources : List SourceKey) (key : SourceKey)
    (ready : reviewReady s intent sources true true true = true)
    (cited : key ∈ sources) :
    (reserveReview s intent sources true true true).consumed key = true := by
  simp [reserveReview, ready, cited]

theorem review_refuses_overlap (s : State) (intent : IntentKey) (sources : List SourceKey)
    (key : SourceKey) (cited : key ∈ sources) (used : s.consumed key = true) :
    reserveReview s intent sources true true true = s := by
  have rejected : reviewReady s intent sources true true true = false := by
    cases h : reviewReady s intent sources true true true with
    | false => rfl
    | true =>
      obtain ⟨a, b⟩ := key
      simp [reviewReady] at h
      exact (Bool.noConfusion (used.symm.trans (h.2 a b cited)))
  simp [reserveReview, rejected]

end BizKitCommercialSetoff
