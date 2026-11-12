import ResearchExchangeBridge.Refinement
import ResearchExchangeBridge.SourceBoundary

set_option autoImplicit false

/- Fixed elaborated statement contracts. Do not regenerate them in CI.
A weakened target must fail these assignments even when it still compiles. -/
namespace ResearchExchangeBridge.FixedContracts
open ResearchExchange
open ResearchExchangeBridge.Encoding

example (xs ys : List UInt8) (h : bytes xs = bytes ys) : xs = ys := by
  exact ResearchExchangeBridge.Encoding.bytes_injective xs ys h

example (s t : String) (h : text s = text t) : s = t := by
  exact ResearchExchangeBridge.Encoding.text_injective s t h

example (xs ys : List (Fin 257)) (h : digits xs = digits ys) : xs = ys := by
  exact ResearchExchangeBridge.Encoding.digits_injective xs ys h

example (field : List UInt8) (rest : List (Fin 257)) :
    unframe (field.map byteDigit ++ separator :: rest) =
      field.map UInt8.toNat :: unframe rest := by
  exact ResearchExchangeBridge.Encoding.unframe_field field rest

example (fields : List (List UInt8)) :
    unframe (frame fields) = fields.map (List.map UInt8.toNat) := by
  exact ResearchExchangeBridge.Encoding.unframe_frame fields

example (xs ys : List UInt8)
    (h : xs.map UInt8.toNat = ys.map UInt8.toNat) : xs = ys := by
  exact ResearchExchangeBridge.Encoding.map_bytes_injective xs ys h

example (xs ys : List (List UInt8)) (h : frame xs = frame ys) : xs = ys := by
  exact ResearchExchangeBridge.Encoding.frame_injective xs ys h

example (xs ys : List String) (h : fields xs = fields ys) : xs = ys := by
  exact ResearchExchangeBridge.Encoding.fields_injective xs ys h

example (a b : ReceiptBinding) (h : sourceFields a = sourceFields b) :
    a = b := by
  exact ResearchExchangeBridge.sourceFields_injective a b h

example (a b : ReceiptBinding) (h : projectBinding a = projectBinding b) :
    a = b := by
  exact ResearchExchangeBridge.projectBinding_injective a b h

example (a b : ReceiptBinding)
    (h : projectCandidate a = projectCandidate b) : a = b := by
  exact ResearchExchangeBridge.projectCandidate_injective a b h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    Adapter.eligible (projectConfig cfg) (projectRow s).adapter
      (projectIdentity s who p) (projectPrepared p) := by
  exact ResearchExchangeBridge.ready_implies_core_eligible cfg s who p h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    Closure.rejectable (projectConfig cfg) (projectRow s)
      (projectIdentity s who p) (projectPrepared p) := by
  exact ResearchExchangeBridge.ready_implies_core_rejectable cfg s who p h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    projectRow (step cfg s who p .accepted) =
      Closure.decide (projectConfig cfg) (projectRow s) (projectIdentity s who p)
        (projectPrepared p) .accepted := by
  exact ResearchExchangeBridge.accepted_refines_closure cfg s who p h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    projectRow (step cfg s who p .rejected) =
      Closure.decide (projectConfig cfg) (projectRow s) (projectIdentity s who p)
        (projectPrepared p) .definitiveRejection := by
  exact ResearchExchangeBridge.rejected_refines_closure cfg s who p h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared) :
    step cfg s who p .inconclusive = s := by
  exact ResearchExchangeBridge.inconclusive_is_inert cfg s who p

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : ¬ready cfg s who p) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.refusal_is_inert cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) : projectRow (step cfg s who p v) = coreResult cfg s who p v := by
  exact ResearchExchangeBridge.step_refines_closure cfg s who p v

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) : (step cfg s who p v).binding = s.binding := by
  exact ResearchExchangeBridge.receipt_binding_immutable cfg s who p v

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) :
    (step cfg s who p v).verifier_enabled = s.verifier_enabled ∧
    (step cfg s who p v).authority_epoch = s.authority_epoch ∧
    (step cfg s who p v).requester_enabled = s.requester_enabled ∧
    (step cfg s who p v).requester_epoch = s.requester_epoch := by
  exact ResearchExchangeBridge.authority_snapshot_unchanged cfg s who p v

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) : total (step cfg s who p v) = total s := by
  exact ResearchExchangeBridge.conservation cfg s who p v

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) : s.version ≤ (step cfg s who p v).version := by
  exact ResearchExchangeBridge.version_monotone cfg s who p v

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.payouts ≤ 1) : (step cfg s who p v).payouts ≤ 1 := by
  exact ResearchExchangeBridge.at_most_one_payout cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.phase = .accepted ∨ s.phase = .rejected) :
    step cfg s who p v = s := by
  exact ResearchExchangeBridge.terminal_is_inert cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    let out := step cfg s who p .accepted
    out.phase = .accepted ∧ out.payouts = 1 ∧ out.settlement = true ∧
    out.refund_amount = none ∧ out.escrow = 0 ∧ out.balance_a = s.balance_a + cfg.reward ∧
    out.version = s.version + 1 := by
  exact ResearchExchangeBridge.accepted_effect cfg s who p h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (h : ready cfg s who p) :
    let out := step cfg s who p .rejected
    out.phase = .rejected ∧ out.payouts = 0 ∧ out.settlement = false ∧
    out.refund_amount = some cfg.reward ∧ out.escrow = 0 ∧
    out.funder = s.funder + cfg.reward ∧ out.version = s.version + 1 := by
  exact ResearchExchangeBridge.rejected_effect cfg s who p h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) : step cfg (step cfg s who p v) who p v = step cfg s who p v := by
  exact ResearchExchangeBridge.retry_is_inert cfg s who p v

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.binding ≠ cfg.expected) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.wrong_source_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.binding ≠ s.binding) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.substituted_receipt_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : who.authenticated = false) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.unauthenticated_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : who.principal ≠ cfg.verifier) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.wrong_verifier_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : who.requester ≠ s.binding.contributor) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.wrong_requester_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.requester_enabled = false) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.revoked_requester_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.requester_epoch ≠ s.requester_epoch) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.stale_requester_epoch_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.verifier_enabled = false) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.revoked_verifier_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.authority_epoch ≠ s.authority_epoch) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.stale_authority_epoch_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.checked = false) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.unchecked_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.profile ≠ cfg.profile) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.wrong_profile_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : p.version ≠ s.version) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.stale_version_refused cfg s who p v h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (v : Verdict) (h : s.escrow ≠ cfg.reward) : step cfg s who p v = s := by
  exact ResearchExchangeBridge.wrong_escrow_refused cfg s who p v h

end ResearchExchangeBridge.FixedContracts


namespace ResearchExchangeBridge.SourceBoundary.FixedContracts

example (b : Binding) (allowed : List String) (e : Evidence)
    (h : Admissible b allowed (some e)) :
    e.binding.source = b.source ∧ e.binding.target = b.target ∧
    e.binding.statement = b.statement ∧ e.binding.libraryRevision = b.libraryRevision ∧
    e.binding.environment = b.environment ∧ e.binding.policy = b.policy :=
  binds b allowed e h

example (b : Binding) (allowed : List String) (e : Evidence)
    (h : Admissible b allowed (some e)) : e.kernelClosure = e.independentClosure :=
  replaysSameClosure b allowed e h

example (b : Binding) (allowed : List String) (e : Evidence) (a : String)
    (used : a ∈ e.axioms) (prohibited : a ∉ allowed) :
    ¬ Admissible b allowed (some e) :=
  prohibits b allowed e a used prohibited

example (b : Binding) (allowed : List String) : ¬ Admissible b allowed none :=
  incomplete b allowed

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (statement : String) (allowed : List String) (result : Option Evidence)
    (h : ¬ Admissible (expectedBinding p.binding statement) allowed result) :
    advance cfg s who p statement allowed result = s :=
  refusedStutters cfg s who p statement allowed result h

example (cfg : Config) (s : Row) (who : Identity) (p : Prepared)
    (statement : String) (allowed : List String) (result : Option Evidence)
    (h : ¬ ready cfg s who {p with checked := true}) :
    advance cfg s who p statement allowed result = s :=
  staleStutters cfg s who p statement allowed result h

end ResearchExchangeBridge.SourceBoundary.FixedContracts
