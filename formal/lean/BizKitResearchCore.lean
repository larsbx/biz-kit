import Lean

/-!
# FieldWitness consent-release proof (abstract model)

This models one oral-history record: a fixed narrator roster, one community,
and grants for exact material/audience pairs. Sponsor and operator approvals
cannot replace narrator or community grants; withdrawal removes eligibility
for future releases. The model is deliberately abstract: no cryptographic
verification, signer-to-person identity binding, host source resolution,
event ordering, retention policy, export recall or Elixir refinement is proved.
-/

namespace BizKitResearchCore

inductive Actor where
  | narrator (id : Nat)
  | community
  | sponsor (id : Nat)
  | operator (id : Nat)
  deriving DecidableEq

inductive Material where
  | audio
  | transcript
  | excerpt
  deriving DecidableEq

inductive Audience where
  | research
  | publicRelease
  deriving DecidableEq

structure Record where
  narrators : List Nat
  grants : Actor → Material → Audience → Prop

/-- Only the community and every registered narrator can authorize release. -/
def eligible (s : Record) (m : Material) (a : Audience) : Prop :=
  s.grants .community m a ∧
    ∀ n, n ∈ s.narrators → s.grants (.narrator n) m a

def grant (s : Record) (actor : Actor) (m : Material) (a : Audience) : Record :=
  { s with grants := fun who kind audience =>
      (who = actor ∧ kind = m ∧ audience = a) ∨ s.grants who kind audience }

def revoke (s : Record) (actor : Actor) (m : Material) (a : Audience) : Record :=
  { s with grants := fun who kind audience =>
      s.grants who kind audience ∧ ¬ (who = actor ∧ kind = m ∧ audience = a) }

/-- Withdrawing a community grant makes that exact release ineligible. -/
theorem community_revocation_denies (s : Record) (m : Material) (a : Audience) :
    ¬ eligible (revoke s .community m a) m a := by
  intro h
  exact h.1.2 ⟨rfl, rfl, rfl⟩

/-- Withdrawing a named narrator's grant makes that release ineligible. -/
theorem narrator_revocation_denies (s : Record) (n : Nat) (m : Material)
    (a : Audience) (hn : n ∈ s.narrators) :
    ¬ eligible (revoke s (.narrator n) m a) m a := by
  intro h
  exact (h.2 n hn).2 ⟨rfl, rfl, rfl⟩

theorem sponsor_no_authority (s : Record) (id : Nat) (m : Material) (a : Audience) :
    eligible (grant s (.sponsor id) m a) m a ↔ eligible s m a := by
  simp [eligible, grant]

theorem operator_no_authority (s : Record) (id : Nat) (m : Material) (a : Audience) :
    eligible (grant s (.operator id) m a) m a ↔ eligible s m a := by
  simp [eligible, grant]

/-- Proof Bank obligation: sponsorship or business operation is not cultural
permission; withdrawing community approval prevents future release. -/
theorem obligation (s : Record) (m : Material) (a : Audience)
    (sponsorId operatorId : Nat) :
    (eligible (grant s (.sponsor sponsorId) m a) m a ↔ eligible s m a) ∧
    (eligible (grant s (.operator operatorId) m a) m a ↔ eligible s m a) ∧
    ¬ eligible (revoke s .community m a) m a := by
  exact ⟨sponsor_no_authority s sponsorId m a,
    operator_no_authority s operatorId m a,
    community_revocation_denies s m a⟩

/-- Negative control: a flawed sponsor-only rule accepts a record that
the cultural-permission rule correctly denies. -/
def sponsorOnly (s : Record) (m : Material) (a : Audience) : Prop :=
  ∃ id, s.grants (.sponsor id) m a

def empty : Record := { narrators := [0], grants := fun _ _ _ => False }

theorem sponsor_only_counterexample :
    sponsorOnly (grant empty (.sponsor 7) .transcript .publicRelease) .transcript .publicRelease ∧
      ¬ eligible (grant empty (.sponsor 7) .transcript .publicRelease) .transcript .publicRelease := by
  constructor
  · refine ⟨7, ?_⟩
    exact Or.inl ⟨rfl, rfl, rfl⟩
  · simp [eligible, grant, empty]

end BizKitResearchCore
