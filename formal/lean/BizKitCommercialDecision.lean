import Std

namespace BizKitCommercialDecision

structure Request where
  reservation : Nat
  sources : List Nat
  epoch : Nat
  expires : Nat
  evidenceOK : Bool
  independent : Bool
  deriving DecidableEq

structure Snapshot where
  reservation : Nat
  sources : List Nat
  owners : List Nat
  epoch : Nat
  now : Nat
  version : Nat
  deriving DecidableEq

def Ready (s : Snapshot) (r : Request) : Prop :=
  r.reservation = s.reservation ∧ r.sources = s.sources ∧
  s.owners = s.sources.map (fun _ => r.reservation) ∧
  r.epoch = s.epoch ∧ s.now < r.expires ∧
  r.evidenceOK = true ∧ r.independent = true

instance (s : Snapshot) (r : Request) : Decidable (Ready s r) := by
  unfold Ready
  infer_instance

structure State where
  snapshot : Snapshot
  history : List (Snapshot × Request)
  openObligations : List Nat
  postings : List Nat
  settlements : List Nat

def commit (s : State) (prepared : Snapshot) (r : Request) : State :=
  if prepared = s.snapshot ∧ Ready s.snapshot r ∧
      (s.snapshot, r) ∉ s.history then
    { s with history := (s.snapshot, r) :: s.history }
  else s

theorem inert (s : State) (p : Snapshot) (r : Request) :
    (commit s p r).snapshot = s.snapshot ∧
    (commit s p r).openObligations = s.openObligations ∧
    (commit s p r).postings = s.postings ∧
    (commit s p r).settlements = s.settlements := by
  unfold commit
  split <;> simp

theorem history_change_requires_current_evidence (s : State) (p : Snapshot)
    (r : Request) (changed : (commit s p r).history ≠ s.history) :
    p = s.snapshot ∧ Ready s.snapshot r := by
  unfold commit at changed
  split at changed
  · rename_i h
    exact ⟨h.1, h.2.1⟩
  · exact False.elim (changed rfl)

theorem stale_or_interrupted (s : State) (p : Snapshot) (r : Request)
    (h : p ≠ s.snapshot ∨ ¬ Ready s.snapshot r) : commit s p r = s := by
  unfold commit
  rcases h with h | h <;> simp [h]

theorem exact_retry_stutters (s : State) (p : Snapshot) (r : Request)
    (h : (s.snapshot, r) ∈ s.history) : commit s p r = s := by
  simp [commit, h]

theorem exact_retry_after_commit (s : State) (p : Snapshot) (r : Request) :
    commit (commit s p r) p r = commit s p r := by
  unfold commit
  split
  · rename_i h
    simp [h]
  · rename_i h
    simp

theorem expired_cannot_change (s : State) (p : Snapshot) (r : Request)
    (h : r.expires ≤ s.snapshot.now) : commit s p r = s := by
  apply stale_or_interrupted
  exact Or.inr (fun ready => Nat.not_lt_of_ge h ready.2.2.2.2.1)

theorem substituted_sources_cannot_change (s : State) (p : Snapshot) (r : Request)
    (h : r.sources ≠ s.snapshot.sources) : commit s p r = s :=
  stale_or_interrupted s p r (Or.inr (fun ready => h ready.2.1))

theorem competing_owner_cannot_change (s : State) (p : Snapshot) (r : Request)
    (h : s.snapshot.owners ≠ s.snapshot.sources.map (fun _ => r.reservation)) :
    commit s p r = s :=
  stale_or_interrupted s p r (Or.inr (fun ready => h ready.2.2.1))

theorem stale_authority_cannot_change (s : State) (p : Snapshot) (r : Request)
    (h : r.epoch ≠ s.snapshot.epoch) : commit s p r = s :=
  stale_or_interrupted s p r (Or.inr (fun ready => h ready.2.2.2.1))

theorem dependent_consent_cannot_change (s : State) (p : Snapshot) (r : Request)
    (h : r.independent = false) : commit s p r = s :=
  stale_or_interrupted s p r (Or.inr (by simp [Ready, h]))

end BizKitCommercialDecision
