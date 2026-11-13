import ResearchExchangeBridge.Model

namespace ResearchExchangeBridge.SourceBoundary

/-- Byte identities are abstract here. Runtime evidence must relate them to actual
    bytes under the collision-resistance and trusted-tool premises. -/
structure Binding where
  source : String
  target : String
  statement : String
  libraryRevision : String
  environment : String
  policy : String
  deriving DecidableEq

structure Evidence where
  binding : Binding
  exportedClosure : String
  kernelClosure : String
  independentClosure : String
  axioms : List String

def Admissible (expected : Binding) (allowed : List String) (result : Option Evidence) : Prop :=
  ∃ evidence, result = some evidence ∧ evidence.binding = expected ∧
    evidence.exportedClosure ≠ "" ∧
    evidence.kernelClosure = evidence.exportedClosure ∧
    evidence.independentClosure = evidence.exportedClosure ∧
    ∀ axiomName ∈ evidence.axioms, axiomName ∈ allowed

theorem binds (expected : Binding) (allowed : List String) (e : Evidence)
    (h : Admissible expected allowed (some e)) :
    e.binding.source = expected.source ∧ e.binding.target = expected.target ∧
    e.binding.statement = expected.statement ∧
    e.binding.libraryRevision = expected.libraryRevision ∧
    e.binding.environment = expected.environment ∧ e.binding.policy = expected.policy := by
  obtain ⟨_, identity, bound, _⟩ := h
  cases Option.some.inj identity
  subst expected
  exact ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem replaysSameClosure (expected : Binding) (allowed : List String) (e : Evidence)
    (h : Admissible expected allowed (some e)) :
    e.kernelClosure = e.independentClosure := by
  obtain ⟨_, identity, _, _, kernel, independent, _⟩ := h
  cases Option.some.inj identity
  exact kernel.trans independent.symm

theorem prohibits (expected : Binding) (allowed : List String) (e : Evidence) (a : String)
    (used : a ∈ e.axioms) (prohibited : a ∉ allowed) :
    ¬ Admissible expected allowed (some e) := by
  rintro ⟨_, identity, _, _, _, _, permitted⟩
  cases Option.some.inj identity
  exact prohibited (permitted a used)

theorem incomplete (expected : Binding) (allowed : List String) :
    ¬ Admissible expected allowed none := by
  rintro ⟨_, impossible, _⟩
  contradiction

/-- The target statement comes from the immutable source profile. The other
    input identities project directly from the existing durable receipt. -/
def expectedBinding (b : ReceiptBinding) (statement : String) : Binding :=
  ⟨b.artifact_sha256, b.target, statement, b.source_revision, b.environment_sha256, b.policy_sha256⟩

/-- Source evidence supplies the checked premise of the existing row transition. -/
noncomputable def advance (cfg : Config) (state : Row) (who : Identity) (p : Prepared)
    (statement : String) (allowed : List String) (result : Option Evidence) : Row := by
  classical
  exact if Admissible (expectedBinding p.binding statement) allowed result then
    step cfg state who {p with checked := true} .accepted
  else state

theorem refusedStutters (cfg : Config) (state : Row) (who : Identity) (p : Prepared)
    (statement : String) (allowed : List String) (result : Option Evidence)
    (h : ¬ Admissible (expectedBinding p.binding statement) allowed result) :
    advance cfg state who p statement allowed result = state := by
  simp [advance, h]

theorem staleStutters (cfg : Config) (state : Row) (who : Identity) (p : Prepared)
    (statement : String) (allowed : List String) (result : Option Evidence)
    (h : ¬ ready cfg state who {p with checked := true}) :
    advance cfg state who p statement allowed result = state := by
  unfold advance
  split
  · simp [step, h]
  · rfl

end ResearchExchangeBridge.SourceBoundary
