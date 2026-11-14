import CrossCurrencySetoff

/-!
Independent proposition contracts. These are explicit expected types, not types
obtained by inspecting the theorem being checked. Changing a theorem to `True`,
weakening feasibility, dropping a source revision, or changing a dimension must
fail this module. Every contract is named, inventoried and transitively axiom-audited;
an axiom in a contract cannot escape by leaving the core proof dependencies clean.
Arithmetic contract expressions intentionally expand the public
abbreviations and the exact offset formulas.
-/
open CrossCurrencySetoff

namespace CrossCurrencySetoff.Contracts

theorem check_exact_iff_common_multiplier {n d q b : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1) :
    n * b = d * q ↔ ∃ k, q = k * n ∧ b = k * d := exact_iff_common_multiplier h

theorem check_canonical_unique {n d n' d' : Nat}
    (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (h' : 0 < n' ∧ 0 < d' ∧ Nat.gcd n' d' = 1)
    (he : n * d' = n' * d) : n = n' ∧ d = d' := canonical_unique h h' he

theorem check_quote_reduction_bounded (Q B n d : Nat) (hn : 0 < n) : min (B / d) (Q / n) * n ≤ Q :=
  quote_reduction_bounded Q B n d hn

theorem check_base_reduction_bounded (Q B n d : Nat) (hd : 0 < d) : min (B / d) (Q / n) * d ≤ B :=
  base_reduction_bounded Q B n d hd

theorem check_quote_conservation (Q B n d : Nat) (hn : 0 < n) :
    (Q - min (B / d) (Q / n) * n) + min (B / d) (Q / n) * n = Q :=
  quote_conservation Q B n d hn

theorem check_base_conservation (Q B n d : Nat) (hd : 0 < d) :
    (B - min (B / d) (Q / n) * d) + min (B / d) (Q / n) * d = B :=
  base_conservation Q B n d hd

theorem check_residuals_nonnegative (Q B n d : Nat) :
    0 ≤ Q - min (B / d) (Q / n) * n ∧ 0 ≤ B - min (B / d) (Q / n) * d :=
  residuals_nonnegative Q B n d

theorem check_integer_residuals (Q B n d : Nat) (hn : 0 < n) (hd : 0 < d) :
    ((Q - min (B / d) (Q / n) * n : Nat) : Int) =
      (Q : Int) - ((min (B / d) (Q / n) * n : Nat) : Int) ∧
    ((B - min (B / d) (Q / n) * d : Nat) : Int) =
      (B : Int) - ((min (B / d) (Q / n) * d : Nat) : Int) :=
  integer_residuals Q B n d hn hd

theorem check_proposed_exact (Q B n d : Nat) :
    n * (min (B / d) (Q / n) * d) = d * (min (B / d) (Q / n) * n) :=
  proposed_exact Q B n d

theorem check_proposed_feasible (Q B n d : Nat) (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1) :
    min (B / d) (Q / n) * n ≤ Q ∧ min (B / d) (Q / n) * d ≤ B ∧
    n * (min (B / d) (Q / n) * d) = d * (min (B / d) (Q / n) * n) :=
  proposed_feasible Q B n d h

theorem check_multiplier_feasible_iff {Q B n d k : Nat} (hn : 0 < n) (hd : 0 < d) :
    k * n ≤ Q ∧ k * d ≤ B ↔ k ≤ min (B / d) (Q / n) :=
  multiplier_feasible_iff hn hd

theorem check_maximum_exact_offset {Q B n d q b : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (hf : q ≤ Q ∧ b ≤ B ∧ n * b = d * q) :
    q ≤ min (B / d) (Q / n) * n ∧ b ≤ min (B / d) (Q / n) * d :=
  maximum_exact_offset h hf

theorem check_no_larger_exact_offset {Q B n d q b : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (hlarger : min (B / d) (Q / n) * n < q ∨ min (B / d) (Q / n) * d < b) :
    ¬ (q ≤ Q ∧ b ≤ B ∧ n * b = d * q) := no_larger_exact_offset h hlarger

theorem check_refusal_iff_no_positive_exact {Q B n d : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1) :
    min (B / d) (Q / n) = 0 ↔
      ¬ ∃ q b, 0 < q ∧ 0 < b ∧ q ≤ Q ∧ b ≤ B ∧ n * b = d * q :=
  refusal_iff_no_positive_exact h

theorem check_residual_exhaustion {Q B n d : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1) :
    Q - min (B / d) (Q / n) * n < n ∨ B - min (B / d) (Q / n) * d < d :=
  residual_exhaustion h

theorem check_exact_quote_divisible {n d q b : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (he : n * b = d * q) : n ∣ q := exact_quote_divisible h he

theorem check_exact_base_divisible {n d q b : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (he : n * b = d * q) : d ∣ b := exact_base_divisible h he

theorem check_reduction_machine_bound {Q B n d : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (hQ : Q ≤ 9007199254740991) (hB : B ≤ 9007199254740991) :
    min (B / d) (Q / n) * n ≤ 9007199254740991 ∧
    min (B / d) (Q / n) * d ≤ 9007199254740991 := reduction_machine_bound h hQ hB

theorem check_scalar_aggregation_breaks_quote_conservation {Q B n d : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (hk : 0 < min (B / d) (Q / n)) :
    (Q - min (B / d) (Q / n) * n) +
      (min (B / d) (Q / n) * n + min (B / d) (Q / n) * d) ≠ Q :=
  scalar_aggregation_breaks_quote_conservation h hk

theorem check_accepted_is_assembled {r : Request} {p : Preview} (h : propose r = some p) : p = assemble r :=
  accepted_is_assembled h

theorem check_accepted_assertions_valid {r : Request} {p : Preview} (h : propose r = some p) : AssertionsValid r :=
  accepted_assertions_valid h

theorem check_preserves_both_sources {r : Request} {p : Preview} (h : propose r = some p) :
    p.request.quoteSource = r.quoteSource ∧ p.request.baseSource = r.baseSource :=
  preserves_both_sources h

theorem check_preserves_independent_source_identities {r : Request} {p : Preview} (h : propose r = some p) :
    p.quoteRow.sourceId = r.quoteSource.id ∧ p.quoteRow.sourceRevision = r.quoteSource.revision ∧
    p.quoteRow.currency = r.quoteSource.currency ∧ p.baseRow.sourceId = r.baseSource.id ∧
    p.baseRow.sourceRevision = r.baseSource.revision ∧ p.baseRow.currency = r.baseSource.currency :=
  preserves_independent_source_identities h

theorem check_distinct_sources_stay_distinct {r : Request} {p : Preview} (h : propose r = some p) :
    p.quoteRow.sourceId ≠ p.baseRow.sourceId := distinct_sources_stay_distinct h

theorem check_distinct_currencies_stay_distinct {r : Request} {p : Preview} (h : propose r = some p) :
    p.quoteRow.currency ≠ p.baseRow.currency := distinct_currencies_stay_distinct h

theorem check_accepted_conservation {r : Request} {p : Preview} (h : propose r = some p) :
    p.quoteRow.residual + p.quoteRow.reduction = p.quoteRow.original ∧
    p.baseRow.residual + p.baseRow.reduction = p.baseRow.original := accepted_conservation h

theorem check_mismatched_quote_revision_refused {r : Request} {p : Preview}
    (hne : p.quoteRow.sourceRevision ≠ r.quoteSource.revision) : propose r ≠ some p :=
  mismatched_quote_revision_refused hne

theorem check_substituted_source_refused {r : Request} {p : Preview}
    (hne : p.quoteRow.sourceId ≠ r.quoteSource.id ∨ p.baseRow.sourceId ≠ r.baseSource.id) :
    propose r ≠ some p := substituted_source_refused hne

theorem check_expired_agreement_refused {r : Request} (h : r.agreement.validUntil ≤ r.observedAt) : propose r = none :=
  expired_agreement_refused h

theorem check_future_agreement_refused {r : Request} (h : r.observedAt < r.agreement.agreedAt) : propose r = none :=
  future_agreement_refused h

theorem check_noncanonical_rate_refused {r : Request} (h : ¬ (0 < r.agreement.numerator ∧ 0 < r.agreement.denominator ∧
    Nat.gcd r.agreement.numerator r.agreement.denominator = 1)) : propose r = none :=
  noncanonical_rate_refused h

theorem check_accepted_no_effects {r : Request} {p : Preview} (h : propose r = some p) :
    p.admitted = false ∧ p.authenticatedConsent = false ∧ p.debtDischarged = false ∧
    p.accountingPosted = false ∧ p.paymentExecuted = false ∧ p.fxExecuted = false ∧
    p.favorableLegalClassification = false := accepted_no_effects h

theorem check_changed_observation_refused {p : Preview} {now : Nat} (h : now ≠ p.request.observedAt) : verifyPlan p now = false :=
  changed_observation_refused h

theorem check_accepted_exact {r : Request} {p : Preview} (h : propose r = some p) :
    r.agreement.numerator * p.baseRow.reduction =
      r.agreement.denominator * p.quoteRow.reduction := accepted_exact h

theorem check_accepted_maximum_exact_offset {r : Request} {p : Preview} {q b : Nat} (h : propose r = some p)
    (hf : q ≤ r.quoteSource.amount ∧ b ≤ r.baseSource.amount ∧
      r.agreement.numerator * b = r.agreement.denominator * q) :
    q ≤ p.quoteRow.reduction ∧ b ≤ p.baseRow.reduction := accepted_maximum_exact_offset h hf

theorem check_mismatched_base_revision_refused {r : Request} {p : Preview}
    (hne : p.baseRow.sourceRevision ≠ r.baseSource.revision) : propose r ≠ some p :=
  mismatched_base_revision_refused hne

theorem check_changed_source_snapshot_changes_preview {r r' : Request} {p p' : Preview} (h : propose r = some p) (h' : propose r' = some p')
    (hchanged : r.quoteSource ≠ r'.quoteSource ∨ r.baseSource ≠ r'.baseSource) : p ≠ p' :=
  changed_source_snapshot_changes_preview h h' hchanged

theorem check_expired_source_refused {r : Request} (h : r.quoteSource.validUntil ≤ r.observedAt ∨
    r.baseSource.validUntil ≤ r.observedAt) : propose r = none := expired_source_refused h

theorem check_same_currency_refused {r : Request} (h : r.quoteSource.currency = r.baseSource.currency) : propose r = none :=
  same_currency_refused h

theorem check_no_exact_offset_refused {r : Request} (h : min (r.baseSource.amount / r.agreement.denominator)
    (r.quoteSource.amount / r.agreement.numerator) = 0) : propose r = none := no_exact_offset_refused h

end CrossCurrencySetoff.Contracts
