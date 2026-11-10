import ResearchExchange.Reward

namespace ResearchExchange.Adapter

/-!
This module models the controlled verifier-to-durable-state boundary for one
already admitted reward candidate. It calls the existing `Reward.accept`; it
does not replace the reward transition with a second implementation.

`RequestIdentity.authenticated` is the premise supplied by the credential check
inside the committing transaction. `Prepared.checked` is the premise supplied
by the controlled check of the immutable, profile-bound artifact. Natural-number
identifiers stand for exact identities/commitments, not cryptographic functions.
Configuration is immutable throughout an execution. Atomic durable publication
and recovery are explicit assumptions of this model, to be exercised separately
by the SQLite/process-crash acceptance tests; Lean does not verify SQLite, HTTP,
the checker executables, token hashing, or the operating system.

Reachability here starts from a supplied durable admission state and covers
verification commits and grant revocation. Worker routes and preparation do not
become authenticated merely by proving these theorems.
-/

structure Config where
  reward : Reward.Config
  verifier : Nat
  profile : Nat
  deriving DecidableEq, Repr

structure State where
  reward : Reward.State
  version : Nat
  verifierEnabled : Bool
  verifierEpoch : Nat
  settlement : Option Candidate
  deriving DecidableEq, BEq, Repr

structure RequestIdentity where
  authenticated : Bool
  principal : Nat
  deriving DecidableEq, BEq, Repr

structure Prepared where
  candidate : Candidate
  profile : Nat
  version : Nat
  authorityEpoch : Nat
  checked : Bool
  deriving DecidableEq, BEq, Repr

/-- Every field is revalidated against the state used for the atomic commit.
    Role and slot scope are part of the authenticated-identity premise. -/
def eligible (cfg : Config) (s : State) (who : RequestIdentity) (p : Prepared) : Prop :=
  who.authenticated = true ∧ who.principal = cfg.verifier ∧
  s.verifierEnabled = true ∧ p.authorityEpoch = s.verifierEpoch ∧
  p.checked = true ∧ p.profile = cfg.profile ∧ p.version = s.version ∧
  s.reward.candidate = some p.candidate ∧ s.settlement = none

instance (cfg : Config) (s : State) (who : RequestIdentity) (p : Prepared) :
    Decidable (eligible cfg s who p) :=
  inferInstanceAs (Decidable
    (who.authenticated = true ∧ who.principal = cfg.verifier ∧
    s.verifierEnabled = true ∧ p.authorityEpoch = s.verifierEpoch ∧
    p.checked = true ∧ p.profile = cfg.profile ∧ p.version = s.version ∧
    s.reward.candidate = some p.candidate ∧ s.settlement = none))

/-- Only a real change by the existing reward kernel can publish a settlement.
    Reward, settlement, and the row version are published as one state. -/
def commit (cfg : Config) (s : State) (who : RequestIdentity) (p : Prepared) : State :=
  if eligible cfg s who p then
    let reward' := Reward.accept cfg.reward s.reward true p.candidate
    if reward' = s.reward then s
    else { s with reward := reward', version := s.version + 1,
                  settlement := some p.candidate }
  else s

/-- Revocation durably changes the authority epoch, not the reward row version.
    Repeated revocation of an already-disabled grant is a no-op. -/
def revoke (s : State) : State :=
  if s.verifierEnabled = true then
    { s with verifierEnabled := false, verifierEpoch := s.verifierEpoch + 1 }
  else s

/-- This states the absence of a paid state without its matching settlement,
    and the absence of a settlement without its admitted and paid candidate. -/
def settlementConsistent (s : State) : Prop :=
  (s.settlement = none ∧ s.reward.payouts = 0) ∨
  ∃ c, s.settlement = some c ∧ s.reward.candidate = some c ∧
       s.reward.phase = .accepted ∧ s.reward.payouts = 1

theorem commit_cases (cfg : Config) (s : State) (who : RequestIdentity) (p : Prepared) :
    commit cfg s who p = s ∨
    (eligible cfg s who p ∧ Reward.accept cfg.reward s.reward true p.candidate ≠ s.reward ∧
     commit cfg s who p =
       { s with reward := Reward.accept cfg.reward s.reward true p.candidate,
                version := s.version + 1, settlement := some p.candidate }) := by
  unfold commit
  split
  · rename_i guards
    dsimp only
    split
    · exact Or.inl rfl
    · rename_i changed
      exact Or.inr ⟨guards, changed, rfl⟩
  · exact Or.inl rfl

theorem unauthenticated_refused (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (h : who.authenticated = false) :
    commit cfg s who p = s := by
  simp [commit, eligible, h]

theorem wrong_verifier_refused (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (h : who.principal ≠ cfg.verifier) :
    commit cfg s who p = s := by
  simp [commit, eligible, h]

theorem disabled_verifier_refused (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (h : s.verifierEnabled = false) :
    commit cfg s who p = s := by
  simp [commit, eligible, h]

theorem stale_epoch_refused (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (h : p.authorityEpoch ≠ s.verifierEpoch) :
    commit cfg s who p = s := by
  simp [commit, eligible, h]

theorem unchecked_refused (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (h : p.checked = false) :
    commit cfg s who p = s := by
  simp [commit, eligible, h]

theorem wrong_profile_refused (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (h : p.profile ≠ cfg.profile) :
    commit cfg s who p = s := by
  simp [commit, eligible, h]

theorem stale_version_refused (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (h : p.version ≠ s.version) :
    commit cfg s who p = s := by
  simp [commit, eligible, h]

theorem wrong_candidate_refused (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared)
    (h : s.reward.candidate ≠ some p.candidate) : commit cfg s who p = s := by
  simp [commit, eligible, h]

theorem existing_settlement_refused (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (h : s.settlement ≠ none) :
    commit cfg s who p = s := by
  simp [commit, eligible, h]

theorem failed_reward_transition_refused (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared)
    (h : Reward.accept cfg.reward s.reward true p.candidate = s.reward) :
    commit cfg s who p = s := by
  simp [commit, h]

theorem wrong_binding_refused (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared)
    (h : p.candidate.binding ≠ cfg.reward.expected) : commit cfg s who p = s := by
  exact failed_reward_transition_refused cfg s who p
    (Reward.wrong_evidence_binding_refused cfg.reward s.reward true p.candidate h)

theorem commit_requires_current_authority (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (h : commit cfg s who p ≠ s) :
    eligible cfg s who p := by
  rcases commit_cases cfg s who p with unchanged | ⟨guards, _, _⟩
  · exact (h unchanged).elim
  · exact guards

/-- A successful adapter commit publishes exactly the original kernel's update,
    its candidate settlement, and one version increment, with no grant mutation. -/
theorem atomic_settlement_correspondence (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (h : commit cfg s who p ≠ s) :
    (commit cfg s who p).reward = Reward.accept cfg.reward s.reward true p.candidate ∧
    (commit cfg s who p).settlement = some p.candidate ∧
    (commit cfg s who p).version = s.version + 1 ∧
    (commit cfg s who p).verifierEnabled = s.verifierEnabled ∧
    (commit cfg s who p).verifierEpoch = s.verifierEpoch := by
  rcases commit_cases cfg s who p with unchanged | ⟨_, _, result⟩
  · exact (h unchanged).elim
  · rw [result]
    exact ⟨rfl, rfl, rfl, rfl, rfl⟩

private theorem reward_accept_success (cfg : Reward.Config) (s : Reward.State)
    (c : Candidate) (h : Reward.accept cfg s true c ≠ s) :
    (Reward.accept cfg s true c).candidate = some c ∧
    (Reward.accept cfg s true c).phase = .accepted ∧
    (Reward.accept cfg s true c).payouts = 1 := by
  unfold Reward.accept at h ⊢
  split at h
  · rename_i guards
    rcases guards with ⟨hl, _, hc, hb, hw, hp, he⟩
    simp [hl, hc, hb, hw, hp, he]
  · exact (h rfl).elim

/-- The guards are sufficient as well as necessary: a valid submitted candidate
    with approved checking and live authority really is paid and recorded. -/
theorem valid_checked_candidate_commits (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (hg : eligible cfg s who p)
    (hs : s.reward.phase = .submitted) (hb : p.candidate.binding = cfg.reward.expected)
    (hw : Reward.participant cfg.reward p.candidate.worker) (hp : s.reward.payouts = 0)
    (he : cfg.reward.reward ≤ s.reward.escrow) :
    (commit cfg s who p).reward.phase = .accepted ∧
    (commit cfg s who p).reward.payouts = 1 ∧
    (commit cfg s who p).settlement = some p.candidate ∧
    (commit cfg s who p).version = s.version + 1 := by
  have hc : s.reward.candidate = some p.candidate := hg.2.2.2.2.2.2.2.1
  have changed : Reward.accept cfg.reward s.reward true p.candidate ≠ s.reward := by
    intro same
    have phases := congrArg Reward.State.phase same
    simp [Reward.accept, hs, hc, hb, hw, hp, he] at phases
  simp only [commit, hg, ite_true, changed, ite_false]
  have paid := reward_accept_success cfg.reward s.reward p.candidate changed
  simp [paid.2.1, paid.2.2]

theorem commit_preserves_settlement_consistency (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (hs : settlementConsistent s) :
    settlementConsistent (commit cfg s who p) := by
  rcases commit_cases cfg s who p with unchanged | ⟨_, changed, result⟩
  · rw [unchanged]
    exact hs
  · rcases reward_accept_success cfg.reward s.reward p.candidate changed with ⟨hc, hp, hn⟩
    rw [result]
    exact Or.inr ⟨p.candidate, rfl, hc, hp, hn⟩

theorem commit_preserves_total (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) :
    Reward.total (commit cfg s who p).reward = Reward.total s.reward := by
  rcases commit_cases cfg s who p with unchanged | ⟨_, _, result⟩
  · rw [unchanged]
  · rw [result]
    exact Reward.accept_preserves_total cfg.reward s.reward true p.candidate

theorem commit_preserves_reward_safe (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (hs : Reward.safe cfg.reward s.reward) :
    Reward.safe cfg.reward (commit cfg s who p).reward := by
  rcases commit_cases cfg s who p with unchanged | ⟨_, _, result⟩
  · rw [unchanged]
    exact hs
  · rw [result]
    exact Reward.step_preserves_safe cfg.reward s.reward (.accept true p.candidate) hs

theorem candidate_immutable (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) :
    (commit cfg s who p).reward.candidate = s.reward.candidate := by
  rcases commit_cases cfg s who p with unchanged | ⟨_, _, result⟩
  · rw [unchanged]
  · rw [result]
    dsimp only
    unfold Reward.accept
    split <;> rfl

theorem version_monotone (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) : s.version ≤ (commit cfg s who p).version := by
  rcases commit_cases cfg s who p with unchanged | ⟨_, _, result⟩
  · rw [unchanged]
    exact Nat.le_refl _
  · rw [result]
    exact Nat.le_succ _

/-- An existing durable settlement blocks every further commit, including
    a different request, principal, profile, or candidate. -/
theorem no_duplicate_settlement (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (c : Candidate)
    (hs : s.settlement = some c) : commit cfg s who p = s := by
  apply existing_settlement_refused
  simp [hs]

theorem commit_idempotent (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) :
    commit cfg (commit cfg s who p) who p = commit cfg s who p := by
  rcases commit_cases cfg s who p with unchanged | ⟨_, _, result⟩
  · rw [unchanged]
    exact unchanged
  · apply no_duplicate_settlement cfg _ who p p.candidate
    rw [result]

theorem competing_commit_after_success_refused (cfg : Config) (s : State)
    (who other : RequestIdentity) (p q : Prepared) (h : commit cfg s who p ≠ s) :
    commit cfg (commit cfg s who p) other q = commit cfg s who p := by
  apply no_duplicate_settlement cfg _ other q p.candidate
  exact (atomic_settlement_correspondence cfg s who p h).2.1

theorem revoke_blocks_commit (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) :
    commit cfg (revoke s) who p = revoke s := by
  apply disabled_verifier_refused
  cases enabled : s.verifierEnabled <;> simp [revoke, enabled]

theorem revoke_advances_epoch (s : State) (enabled : s.verifierEnabled = true) :
    s.verifierEpoch < (revoke s).verifierEpoch := by
  simp [revoke, enabled]

theorem revoke_preserves_settlement_consistency (s : State) (hs : settlementConsistent s) :
    settlementConsistent (revoke s) := by
  unfold revoke
  split <;> exact hs

/-- Only these two snapshots can survive an atomic durable commit. This is the
    storage assumption; no theorem here implements or verifies a database. -/
inductive CrashPoint where
  | beforeCommit | afterCommit
  deriving DecidableEq, BEq, Repr

def recover (cfg : Config) (s : State) (who : RequestIdentity) (p : Prepared) :
    CrashPoint → State
  | .beforeCommit => s
  | .afterCommit => commit cfg s who p

theorem crash_recovery_atomic (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (point : CrashPoint) :
    recover cfg s who p point = s ∨
    recover cfg s who p point = commit cfg s who p := by
  cases point with
  | beforeCommit => exact Or.inl rfl
  | afterCommit => exact Or.inr rfl

theorem crash_recovery_preserves_consistency (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (point : CrashPoint)
    (hs : settlementConsistent s) : settlementConsistent (recover cfg s who p point) := by
  cases point with
  | beforeCommit => exact hs
  | afterCommit => exact commit_preserves_settlement_consistency cfg s who p hs

/-- With no intervening operation, a retry reaches the same durable state whether
    the first request died before commit or lost its response after commit. -/
theorem retry_after_crash_or_response_loss (cfg : Config) (s : State)
    (who : RequestIdentity) (p : Prepared) (point : CrashPoint) :
    commit cfg (recover cfg s who p point) who p = commit cfg s who p := by
  cases point with
  | beforeCommit => rfl
  | afterCommit => exact commit_idempotent cfg s who p

inductive Reachable (cfg : Config) (base : State) : State → Prop
  | initial : Reachable cfg base base
  | verifiedCommit {s : State} (h : Reachable cfg base s)
      (who : RequestIdentity) (p : Prepared) : Reachable cfg base (commit cfg s who p)
  | revocation {s : State} (h : Reachable cfg base s) : Reachable cfg base (revoke s)

theorem reachable_settlement_consistency (cfg : Config) (base s : State)
    (hb : settlementConsistent base) (hr : Reachable cfg base s) :
    settlementConsistent s := by
  induction hr with
  | initial => exact hb
  | verifiedCommit _ who p ih => exact commit_preserves_settlement_consistency cfg _ who p ih
  | revocation _ ih => exact revoke_preserves_settlement_consistency _ ih

theorem reachable_conservation (cfg : Config) (base s : State)
    (hr : Reachable cfg base s) : Reward.total s.reward = Reward.total base.reward := by
  induction hr with
  | initial => rfl
  | verifiedCommit _ who p ih => rw [commit_preserves_total, ih]
  | revocation _ ih => unfold revoke; split <;> exact ih

theorem reachable_at_most_one_payout (cfg : Config) (base s : State)
    (hb : settlementConsistent base) (hr : Reachable cfg base s) : s.reward.payouts ≤ 1 := by
  rcases reachable_settlement_consistency cfg base s hb hr with ⟨_, zero⟩ | ⟨_, _, _, _, one⟩
  · omega
  · omega

theorem reachable_settlement_immutable (cfg : Config) (base s : State) (c : Candidate)
    (hb : base.settlement = some c) (hr : Reachable cfg base s) : s.settlement = some c := by
  induction hr with
  | initial => exact hb
  | verifiedCommit _ who p ih => rw [no_duplicate_settlement cfg _ who p c ih]; exact ih
  | revocation _ ih => unfold revoke; split <;> exact ih

/-- Deliberately small reviewed exports for the controlled checker profile. -/
theorem expected_fixture (n : Nat) : n + 0 = n := by rfl

/-- This is valid too, but its export must not pass the expected target profile. -/
theorem alternate_fixture : (2 : Nat) + 3 = 5 := by rfl

end ResearchExchange.Adapter
