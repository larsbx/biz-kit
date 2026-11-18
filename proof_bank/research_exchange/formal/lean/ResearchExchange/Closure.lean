import ResearchExchange.Adapter

namespace ResearchExchange.Closure

/-- A checked positive result and a definitive exact-profile rejection are
    trusted internal evidence. Inconclusive observations carry no authority. -/
inductive Verdict where
  | accepted | definitiveRejection | inconclusive
  deriving DecidableEq, Repr

structure Refund where
  candidate : Candidate
  amount : Nat
  deriving DecidableEq, Repr

structure State where
  adapter : Adapter.State
  refund : Option Refund
  deriving DecidableEq, Repr

def rejectable (cfg : Adapter.Config) (s : State)
    (who : Adapter.RequestIdentity) (p : Adapter.Prepared) : Prop :=
  Adapter.eligible cfg s.adapter who p ∧
  s.adapter.reward.phase = .submitted ∧ s.adapter.reward.payouts = 0 ∧
  s.adapter.reward.escrow = cfg.reward.reward ∧ s.refund = none ∧
  p.candidate.binding = cfg.reward.expected ∧ Reward.participant cfg.reward p.candidate.worker ∧
  0 < cfg.reward.reward

instance (cfg : Adapter.Config) (s : State)
    (who : Adapter.RequestIdentity) (p : Adapter.Prepared) : Decidable (rejectable cfg s who p) :=
  inferInstanceAs (Decidable (Adapter.eligible cfg s.adapter who p ∧
    s.adapter.reward.phase = .submitted ∧ s.adapter.reward.payouts = 0 ∧
    s.adapter.reward.escrow = cfg.reward.reward ∧ s.refund = none ∧
    p.candidate.binding = cfg.reward.expected ∧ Reward.participant cfg.reward p.candidate.worker ∧
    0 < cfg.reward.reward))

/-- One already-funded slot identifies one original escrow. Closure atomically
    empties it into its funder balance and publishes the sole refund effect. -/
def refunded (s : State) (c : Candidate) : State :=
  let a := s.adapter
  let r := a.reward
  let reward := { r with phase := .rejected, escrow := 0, funder := r.funder + r.escrow }
  { adapter := { a with version := a.version + 1, reward := reward }
    refund := some ⟨c, r.escrow⟩ }

def decide (cfg : Adapter.Config) (s : State) (who : Adapter.RequestIdentity)
    (p : Adapter.Prepared) : Verdict → State
  | .accepted => { s with adapter := Adapter.commit cfg s.adapter who p }
  | .definitiveRejection => if rejectable cfg s who p then refunded s p.candidate else s
  | .inconclusive => s

theorem rejection_iff (cfg : Adapter.Config) (s : State) (who : Adapter.RequestIdentity)
    (p : Adapter.Prepared) :
    decide cfg s who p .definitiveRejection ≠ s ↔ rejectable cfg s who p := by
  by_cases h : rejectable cfg s who p
  · have hs := h.2.1
    simp only [decide, h, ite_true, iff_true]
    intro same
    have phase := congrArg (fun t : State => t.adapter.reward.phase) same
    simp [refunded, hs] at phase
  · simp [decide, h]

theorem refund_effect (cfg : Adapter.Config) (s : State) (who : Adapter.RequestIdentity)
    (p : Adapter.Prepared) (h : rejectable cfg s who p) :
    let closed := decide cfg s who p .definitiveRejection
    closed.adapter.reward.phase = .rejected ∧ closed.adapter.reward.payouts = 0 ∧
    closed.adapter.settlement = none ∧ closed.adapter.reward.escrow = 0 ∧
    closed.adapter.reward.funder = s.adapter.reward.funder + cfg.reward.reward ∧
    closed.adapter.reward.balanceA = s.adapter.reward.balanceA ∧
    closed.adapter.reward.balanceB = s.adapter.reward.balanceB ∧
    closed.refund = some ⟨p.candidate, cfg.reward.reward⟩ ∧
    closed.adapter.version = s.adapter.version + 1 := by
  have hp := h.2.2.1
  have he := h.2.2.2.1
  have hn := h.1.2.2.2.2.2.2.2.2
  simp [decide, h, refunded, hp, he, hn]

theorem candidate_immutable (cfg : Adapter.Config) (s : State) (who : Adapter.RequestIdentity)
    (p : Adapter.Prepared) (v : Verdict) :
    (decide cfg s who p v).adapter.reward.candidate = s.adapter.reward.candidate := by
  cases v with
  | accepted => exact Adapter.candidate_immutable cfg s.adapter who p
  | definitiveRejection => simp only [decide]; split <;> rfl
  | inconclusive => rfl

theorem conservation (cfg : Adapter.Config) (s : State) (who : Adapter.RequestIdentity)
    (p : Adapter.Prepared) (v : Verdict) :
    Reward.total (decide cfg s who p v).adapter.reward = Reward.total s.adapter.reward := by
  cases v with
  | accepted => exact Adapter.commit_preserves_total cfg s.adapter who p
  | definitiveRejection =>
    simp only [decide]
    split
    · simp [refunded, Reward.total]
    · rfl
  | inconclusive => rfl

theorem terminal_inertia (cfg : Adapter.Config) (s : State) (who : Adapter.RequestIdentity)
    (p : Adapter.Prepared) (v : Verdict)
    (h : s.adapter.reward.phase = .rejected ∨ s.adapter.reward.phase = .accepted) :
    decide cfg s who p v = s := by
  have hs : s.adapter.reward.phase ≠ .submitted := by
    rcases h with h | h <;> simp [h]
  cases v <;> simp [decide, Adapter.commit, Reward.accept, rejectable, hs]

theorem rejected_reward_is_inert (cfg : Reward.Config) (s : Reward.State)
    (a : Reward.Action) (h : s.phase = .rejected) :
    Reward.step cfg s a = s := by
  cases a <;> simp [Reward.step, Reward.tick, Reward.lease, Reward.submit, Reward.accept, h]

theorem unavailable_is_inert (cfg : Adapter.Config) (s : State)
    (who : Adapter.RequestIdentity) (p : Adapter.Prepared) :
    decide cfg s who p .inconclusive = s := rfl

theorem revoked_cannot_refund (cfg : Adapter.Config) (s : State)
    (who : Adapter.RequestIdentity) (p : Adapter.Prepared) :
    let revoked := { s with adapter := Adapter.revoke s.adapter }
    decide cfg revoked who p .definitiveRejection = revoked := by
  cases h : s.adapter.verifierEnabled <;>
    simp [decide, rejectable, Adapter.eligible, Adapter.revoke, h]

theorem stale_cannot_refund (cfg : Adapter.Config) (s : State)
    (who : Adapter.RequestIdentity) (p : Adapter.Prepared)
    (h : p.version ≠ s.adapter.version ∨ p.authorityEpoch ≠ s.adapter.verifierEpoch) :
    decide cfg s who p .definitiveRejection = s := by
  rcases h with h | h <;> simp [decide, rejectable, Adapter.eligible, h]

/-- Crashes retain either the original snapshot or the entire decision. -/
def recover (cfg : Adapter.Config) (s : State) (who : Adapter.RequestIdentity)
    (p : Adapter.Prepared) (v : Verdict) : Adapter.CrashPoint → State
  | .beforeCommit => s
  | .afterCommit => decide cfg s who p v

theorem rejection_retry_after_crash (cfg : Adapter.Config) (s : State)
    (who : Adapter.RequestIdentity) (p : Adapter.Prepared) (point : Adapter.CrashPoint) :
    decide cfg (recover cfg s who p .definitiveRejection point) who p .definitiveRejection =
      decide cfg s who p .definitiveRejection := by
  cases point with
  | beforeCommit => rfl
  | afterCommit =>
    by_cases h : rejectable cfg s who p
    · exact terminal_inertia cfg _ who p _ (Or.inl (refund_effect cfg s who p h).1)
    · simp [recover, decide, h]

/-- Grant revocation is independent of the reward, including after closure. -/
inductive Reachable (cfg : Adapter.Config) (base : State) : State → Prop
  | initial : Reachable cfg base base
  | decision {s} (prior : Reachable cfg base s)
      (who : Adapter.RequestIdentity) (p : Adapter.Prepared) (v : Verdict) :
      Reachable cfg base (decide cfg s who p v)
  | revocation {s} (prior : Reachable cfg base s) :
      Reachable cfg base { s with adapter := Adapter.revoke s.adapter }

theorem reachable_conservation_and_history (cfg : Adapter.Config) (base s : State)
    (h : Reachable cfg base s) :
    Reward.total s.adapter.reward = Reward.total base.adapter.reward ∧
    s.adapter.reward.candidate = base.adapter.reward.candidate := by
  induction h with
  | initial => exact ⟨rfl, rfl⟩
  | decision _ who p v ih => simpa only [conservation, candidate_immutable] using ih
  | revocation _ ih => unfold Adapter.revoke; split <;> exact ih

/-- Every reachable successor of a rejected snapshot has the same reward,
    settlement, refund effect and reward version. No payout or second refund
    can occur in that suffix, including with different prepared requests. -/
theorem reachable_rejection_inertia (cfg : Adapter.Config) (closed s : State)
    (hp : closed.adapter.reward.phase = .rejected) (h : Reachable cfg closed s) :
    s.adapter.reward = closed.adapter.reward ∧ s.adapter.settlement = closed.adapter.settlement ∧
    s.refund = closed.refund ∧ s.adapter.version = closed.adapter.version := by
  induction h with
  | initial => exact ⟨rfl, rfl, rfl, rfl⟩
  | decision _ who p v ih =>
    rw [terminal_inertia cfg _ who p v (Or.inl ((congrArg Reward.State.phase ih.1).trans hp))]
    exact ih
  | revocation _ ih => unfold Adapter.revoke; split <;> exact ih

theorem exactly_one_refund_no_payout_on_rejected_suffix (cfg : Adapter.Config)
    (s after : State) (who : Adapter.RequestIdentity) (p : Adapter.Prepared)
    (h : rejectable cfg s who p)
    (trace : Reachable cfg (decide cfg s who p .definitiveRejection) after) :
    after.refund = some ⟨p.candidate, cfg.reward.reward⟩ ∧
    after.adapter.reward.phase = .rejected ∧ after.adapter.reward.payouts = 0 ∧
    after.adapter.settlement = none := by
  have closed := refund_effect cfg s who p h
  have suffix := reachable_rejection_inertia cfg _ after closed.1 trace
  exact ⟨suffix.2.2.1.trans closed.2.2.2.2.2.2.2.1,
    (congrArg Reward.State.phase suffix.1).trans closed.1,
    (congrArg Reward.State.payouts suffix.1).trans closed.2.1,
    suffix.2.1.trans closed.2.2.1⟩

end ResearchExchange.Closure
