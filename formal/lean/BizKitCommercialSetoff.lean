import Std

/-!
# Ledger-first commercial clearing: source-level admission safety

This model is NOT the deployed CoopSubstrate append gate, a legal setoff
opinion, a cryptographic verification, or financial settlement. It models
an atomic, source-bound *business admission* under an explicit external
verification premise. The business event is never permission to move funds.

Identifiers are scoped as (chapter, source_id) and (chapter, intent_id).
Revisions/hashes and authority are abstracted to `evidenceOK`; in the
actual implementation these MUST come from authenticated canonical source
history, current grants and legal/policy evidence, not a caller-supplied Bool.
A proof about this state machine is not a runtime refinement proof.
-/

namespace BizKitCommercialSetoff

abbrev SourceKey := Nat × Nat
abbrev IntentKey := Nat × Nat

structure State where
  consumed : Finset SourceKey
  intents : Finset IntentKey
  commits : Nat
  deriving Repr

def initial : State :=
  ⟨∅, ∅, 0⟩

/-- Admission is allowed only for a nonempty exact source set, a fresh intent,
    no already-consumed source, and independently authenticated evidence. -/
def Ready (s : State) (intent : IntentKey) (sources : Finset SourceKey)
    (evidenceOK : Bool) : Prop :=
  evidenceOK = true ∧
  sources.Nonempty ∧
  intent ∉ s.intents ∧
  Disjoint sources s.consumed

/-- One atomic, durable append and its reconstructed source-fence state.
    No partial source consumption is representable in the transition. -/
def admit (s : State) (intent : IntentKey) (sources : Finset SourceKey)
    (evidenceOK : Bool) : State :=
  if Ready s intent sources evidenceOK then
    { consumed := s.consumed ∪ sources
      intents := insert intent s.intents
      commits := s.commits + 1 }
  else s

theorem initial_empty : initial.consumed = ∅ ∧ initial.intents = ∅ ∧
    initial.commits = 0 := by
  simp [initial]

theorem rejects_failed_evidence (s : State) (intent : IntentKey)
    (sources : Finset SourceKey) :
    admit s intent sources false = s := by
  simp [admit, Ready]

theorem rejects_empty_sources (s : State) (intent : IntentKey)
    (evidenceOK : Bool) :
    admit s intent ∅ evidenceOK = s := by
  simp [admit, Ready]

theorem rejected_stutters (s : State) (intent : IntentKey)
    (sources : Finset SourceKey) (evidenceOK : Bool)
    (h : ¬ Ready s intent sources evidenceOK) :
    admit s intent sources evidenceOK = s := by
  simp [admit, h]

theorem accepted_marks_sources (s : State) (intent : IntentKey)
    (sources : Finset SourceKey) (evidenceOK : Bool)
    (h : Ready s intent sources evidenceOK) :
    sources ⊆ (admit s intent sources evidenceOK).consumed := by
  intro source hs
  simp [admit, h, hs]

theorem accepted_marks_intent (s : State) (intent : IntentKey)
    (sources : Finset SourceKey) (evidenceOK : Bool)
    (h : Ready s intent sources evidenceOK) :
    intent ∈ (admit s intent sources evidenceOK).intents := by
  simp [admit, h]

theorem already_consumed_refused (s : State) (intent : IntentKey)
    (sources : Finset SourceKey) (evidenceOK : Bool) (source : SourceKey)
    (hin : source ∈ sources) (hused : source ∈ s.consumed) :
    admit s intent sources evidenceOK = s := by
  have overlap : ¬ Disjoint sources s.consumed := by
    intro hd
    exact (Finset.disjoint_left.mp hd hin) hused
  apply rejected_stutters
  intro h
  exact overlap h.2.2.2

theorem replay_stutters (s : State) (intent : IntentKey)
    (sources : Finset SourceKey) (evidenceOK : Bool)
    (h : Ready s intent sources evidenceOK) :
    admit (admit s intent sources evidenceOK) intent sources evidenceOK =
      admit s intent sources evidenceOK := by
  have hi := accepted_marks_intent s intent sources evidenceOK h
  apply rejected_stutters
  intro hready
  exact hready.2.2.1 hi

theorem overlapping_claim_stutters (s : State) (intent first second : IntentKey)
    (oldSources newSources : Finset SourceKey)
    (evidenceOK nextEvidenceOK : Bool)
    (h : Ready s intent oldSources evidenceOK)
    (source : SourceKey)
    (hin : source ∈ oldSources) (hnew : source ∈ newSources) :
    admit (admit s intent oldSources evidenceOK) second newSources nextEvidenceOK =
      admit s intent oldSources evidenceOK := by
  have consumed := accepted_marks_sources s intent oldSources evidenceOK h hin
  exact already_consumed_refused _ second newSources nextEvidenceOK source hnew consumed

/-- Same aggregate item count can conceal substituted source identities.
    Exact source keys, not aggregate cardinality, must be signed. -/
theorem same_count_not_same_source :
    ({(0, 1), (0, 2)} : Finset SourceKey).card =
      ({(0, 1), (0, 3)} : Finset SourceKey).card ∧
    ({(0, 1), (0, 2)} : Finset SourceKey) ≠
      ({(0, 1), (0, 3)} : Finset SourceKey) := by
  decide

/-- Scoped obligation identifiers may coincide numerically in other chapters
    without becoming the same business claim. -/
theorem chapter_is_part_of_source_identity :
    ((0, 7) : SourceKey) ≠ ((1, 7) : SourceKey) := by
  decide

end BizKitCommercialSetoff
