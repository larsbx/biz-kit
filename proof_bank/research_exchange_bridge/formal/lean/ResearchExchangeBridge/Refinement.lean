import ResearchExchangeBridge.Model

set_option autoImplicit false

namespace ResearchExchangeBridge

open ResearchExchange

set_option maxRecDepth 2048

/-- Raw admission guards establish the existing core's authority/version guard.
Checker truth and authenticated credential lookup are explicit positive facts. -/
theorem ready_implies_core_eligible (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    Adapter.eligible (projectConfig cfg) (projectRow s).adapter
      (projectIdentity s who p) (projectPrepared p) := by
  rcases h with ⟨hs, hp, ha, hv, hr, hen, hre, hve, he, hc, hprof, hver,
    hphase, hpay, hset, href, hesc, hpos⟩
  simp [Adapter.eligible, projectConfig, projectRow, projectIdentity, projectPrepared,
    hs, hp, ha, hv, hr, hen, hre, hve, he, hc, hprof, hver, hset]

theorem ready_implies_core_rejectable (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    Closure.rejectable (projectConfig cfg) (projectRow s)
      (projectIdentity s who p) (projectPrepared p) := by
  have eligible := ready_implies_core_eligible cfg s who p h
  rcases h with ⟨hs, hp, ha, hv, hr, hen, hre, hve, he, hc, hprof, hver,
    hphase, hpay, hset, href, hesc, hpos⟩
  unfold Closure.rejectable
  refine ⟨eligible, ?_⟩
  simp [projectConfig, projectRow, projectPrepared, projectCandidate, projectPhase,
    Reward.participant, hs, hp, hphase, hpay, href, hesc, hpos]

/-- The concrete accepted update is not defined through the core: this theorem
checks its arithmetic, version, candidate, settlement and balances against it. -/
theorem accepted_refines_closure (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    projectRow (step cfg s who p .accepted) =
      Closure.decide (projectConfig cfg) (projectRow s) (projectIdentity s who p)
        (projectPrepared p) .accepted := by
  have eligible := ready_implies_core_eligible cfg s who p h
  have hg := h
  rcases h with ⟨hs, hp, ha, hv, hr, hen, hre, hve, he, hc, hprof, hver,
    hphase, hpay, hset, href, hesc, hpos⟩
  have changed : Reward.accept (projectConfig cfg).reward (projectRow s).adapter.reward
      true (projectPrepared p).candidate ≠ (projectRow s).adapter.reward := by
    intro same
    have phase := congrArg Reward.State.phase same
    simp [Reward.accept, projectConfig, projectRow, projectPrepared, projectCandidate,
      projectPhase, Reward.participant, hs, hp, hphase, hpay, hesc] at phase
  simp only [Closure.decide, Adapter.commit, eligible, ite_true, changed, ite_false]
  simp [step, hg, projectRow, projectConfig, projectPrepared, projectCandidate,
    projectPhase, Reward.accept, Reward.participant, hs, hp, hphase, hpay, hset, href, hesc]

theorem rejected_refines_closure (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    projectRow (step cfg s who p .rejected) =
      Closure.decide (projectConfig cfg) (projectRow s) (projectIdentity s who p)
        (projectPrepared p) .definitiveRejection := by
  have rejectable := ready_implies_core_rejectable cfg s who p h
  have hg := h
  rcases h with ⟨hs, hp, ha, hv, hr, hen, hre, hve, he, hc, hprof, hver,
    hphase, hpay, hset, href, hesc, hpos⟩
  simp only [Closure.decide, rejectable, ite_true]
  simp [step, hg, Closure.refunded, projectRow, projectPhase, projectPrepared, hp, hset]

theorem inconclusive_is_inert (cfg : Config) (s : Row) (who : Identity) (p : Prepared) :
    step cfg s who p .inconclusive = s := by
  unfold step
  split <;> rfl

theorem refusal_is_inert (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : ¬ready cfg s who p) : step cfg s who p v = s := by
  simp [step, h]

/-- Forward simulation for every raw input. A refused call is a core stutter;
accepted/rejected calls are the corresponding existing Closure transition. -/
theorem step_refines_closure (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) : projectRow (step cfg s who p v) = coreResult cfg s who p v := by
  by_cases h : ready cfg s who p
  · cases v with
    | accepted => simpa [coreResult, admittedVerdict, h, projectVerdict] using
        accepted_refines_closure cfg s who p h
    | rejected => simpa [coreResult, admittedVerdict, h, projectVerdict] using
        rejected_refines_closure cfg s who p h
    | inconclusive => simp [inconclusive_is_inert, coreResult, admittedVerdict, h,
        projectVerdict, Closure.decide]
  · simp [step, h, coreResult, admittedVerdict, Closure.decide]

theorem receipt_binding_immutable (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) : (step cfg s who p v).binding = s.binding := by
  unfold step
  split
  · cases v <;> rfl
  · rfl

theorem authority_snapshot_unchanged (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) :
    (step cfg s who p v).verifier_enabled = s.verifier_enabled ∧
    (step cfg s who p v).authority_epoch = s.authority_epoch ∧
    (step cfg s who p v).requester_enabled = s.requester_enabled ∧
    (step cfg s who p v).requester_epoch = s.requester_epoch := by
  unfold step
  split
  · cases v <;> exact ⟨rfl, rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl, rfl⟩

def total (s : Row) : Nat := s.funder + s.escrow + s.balance_a + s.balance_b

theorem conservation (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) : total (step cfg s who p v) = total s := by
  change Reward.total (projectRow (step cfg s who p v)).adapter.reward =
    Reward.total (projectRow s).adapter.reward
  rw [step_refines_closure]
  exact Closure.conservation _ _ _ _ _

theorem version_monotone (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) : s.version ≤ (step cfg s who p v).version := by
  unfold step
  split
  · cases v <;> simp
  · exact Nat.le_refl _

theorem at_most_one_payout (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.payouts ≤ 1) : (step cfg s who p v).payouts ≤ 1 := by
  unfold step
  split
  · cases v <;> simp [h]
  · exact h

theorem terminal_is_inert (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.phase = .accepted ∨ s.phase = .rejected) :
    step cfg s who p v = s := by
  rcases h with h | h <;> simp [step, ready, h]

theorem accepted_effect (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    let out := step cfg s who p .accepted
    out.phase = .accepted ∧ out.payouts = 1 ∧ out.settlement = true ∧
    out.refund_amount = none ∧ out.escrow = 0 ∧ out.balance_a = s.balance_a + cfg.reward ∧
    out.version = s.version + 1 := by
  have hg := h
  rcases h with ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, href, hesc, _⟩
  simp [step, hg, href, hesc]

theorem rejected_effect (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    let out := step cfg s who p .rejected
    out.phase = .rejected ∧ out.payouts = 0 ∧ out.settlement = false ∧
    out.refund_amount = some cfg.reward ∧ out.escrow = 0 ∧
    out.funder = s.funder + cfg.reward ∧ out.version = s.version + 1 := by
  have hg := h
  rcases h with ⟨_, _, _, _, _, _, _, _, _, _, _, _, _, hpay, hset, _, hesc, _⟩
  simp [step, hg, hpay, hset, hesc]

theorem retry_is_inert (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) : step cfg (step cfg s who p v) who p v = step cfg s who p v := by
  by_cases h : ready cfg s who p
  · cases v with
    | accepted => apply terminal_is_inert; exact Or.inl (accepted_effect cfg s who p h).1
    | rejected => apply terminal_is_inert; exact Or.inr (rejected_effect cfg s who p h).1
    | inconclusive => simp [inconclusive_is_inert]
  · simp [step, h]

theorem wrong_source_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.binding ≠ cfg.expected) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem substituted_receipt_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.binding ≠ s.binding) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem unauthenticated_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : who.authenticated = false) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem wrong_verifier_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : who.principal ≠ cfg.verifier) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem wrong_requester_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : who.requester ≠ s.binding.contributor) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem revoked_requester_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.requester_enabled = false) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem stale_requester_epoch_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.requester_epoch ≠ s.requester_epoch) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem revoked_verifier_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.verifier_enabled = false) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem stale_authority_epoch_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.authority_epoch ≠ s.authority_epoch) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem unchecked_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.checked = false) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem wrong_profile_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.profile ≠ cfg.profile) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem stale_version_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.version ≠ s.version) : step cfg s who p v = s := by
  simp [step, ready, h]

theorem wrong_escrow_refused (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.escrow ≠ cfg.reward) : step cfg s who p v = s := by
  simp [step, ready, h]

end ResearchExchangeBridge
