import CrossCurrencySetoff

/-!
Independent proposition contracts. These are explicit expected types, not types
obtained by inspecting the theorem being checked. Changing a theorem to `True`,
weakening feasibility, dropping a source revision, or changing a dimension must
fail this module. Arithmetic contract expressions intentionally expand the public
abbreviations and the exact offset formulas.
-/
open CrossCurrencySetoff

example {n d q b : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1) :
    n * b = d * q ↔ ∃ k, q = k * n ∧ b = k * d := exact_iff_common_multiplier h

example {n d n' d' : Nat}
    (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (h' : 0 < n' ∧ 0 < d' ∧ Nat.gcd n' d' = 1)
    (he : n * d' = n' * d) : n = n' ∧ d = d' := canonical_unique h h' he

example (Q B n d : Nat) (hn : 0 < n) : min (B / d) (Q / n) * n ≤ Q :=
  quote_reduction_bounded Q B n d hn

example (Q B n d : Nat) (hd : 0 < d) : min (B / d) (Q / n) * d ≤ B :=
  base_reduction_bounded Q B n d hd

example (Q B n d : Nat) (hn : 0 < n) :
    (Q - min (B / d) (Q / n) * n) + min (B / d) (Q / n) * n = Q :=
  quote_conservation Q B n d hn

example (Q B n d : Nat) (hd : 0 < d) :
    (B - min (B / d) (Q / n) * d) + min (B / d) (Q / n) * d = B :=
  base_conservation Q B n d hd

example (Q B n d : Nat) :
    0 ≤ Q - min (B / d) (Q / n) * n ∧ 0 ≤ B - min (B / d) (Q / n) * d :=
  residuals_nonnegative Q B n d

example (Q B n d : Nat) (hn : 0 < n) (hd : 0 < d) :
    ((Q - min (B / d) (Q / n) * n : Nat) : Int) =
      (Q : Int) - ((min (B / d) (Q / n) * n : Nat) : Int) ∧
    ((B - min (B / d) (Q / n) * d : Nat) : Int) =
      (B : Int) - ((min (B / d) (Q / n) * d : Nat) : Int) :=
  integer_residuals Q B n d hn hd

example (Q B n d : Nat) :
    n * (min (B / d) (Q / n) * d) = d * (min (B / d) (Q / n) * n) :=
  proposed_exact Q B n d

example (Q B n d : Nat) (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1) :
    min (B / d) (Q / n) * n ≤ Q ∧ min (B / d) (Q / n) * d ≤ B ∧
    n * (min (B / d) (Q / n) * d) = d * (min (B / d) (Q / n) * n) :=
  proposed_feasible Q B n d h

example {Q B n d k : Nat} (hn : 0 < n) (hd : 0 < d) :
    k * n ≤ Q ∧ k * d ≤ B ↔ k ≤ min (B / d) (Q / n) :=
  multiplier_feasible_iff hn hd

example {Q B n d q b : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (hf : q ≤ Q ∧ b ≤ B ∧ n * b = d * q) :
    q ≤ min (B / d) (Q / n) * n ∧ b ≤ min (B / d) (Q / n) * d :=
  maximum_exact_offset h hf

example {Q B n d q b : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (hlarger : min (B / d) (Q / n) * n < q ∨ min (B / d) (Q / n) * d < b) :
    ¬ (q ≤ Q ∧ b ≤ B ∧ n * b = d * q) := no_larger_exact_offset h hlarger

example {Q B n d : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1) :
    min (B / d) (Q / n) = 0 ↔
      ¬ ∃ q b, 0 < q ∧ 0 < b ∧ q ≤ Q ∧ b ≤ B ∧ n * b = d * q :=
  refusal_iff_no_positive_exact h

example {Q B n d : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1) :
    Q - min (B / d) (Q / n) * n < n ∨ B - min (B / d) (Q / n) * d < d :=
  residual_exhaustion h

example {n d q b : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (he : n * b = d * q) : n ∣ q := exact_quote_divisible h he

example {n d q b : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (he : n * b = d * q) : d ∣ b := exact_base_divisible h he

example {Q B n d : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (hQ : Q ≤ 9007199254740991) (hB : B ≤ 9007199254740991) :
    min (B / d) (Q / n) * n ≤ 9007199254740991 ∧
    min (B / d) (Q / n) * d ≤ 9007199254740991 := reduction_machine_bound h hQ hB

example {Q B n d : Nat} (h : 0 < n ∧ 0 < d ∧ Nat.gcd n d = 1)
    (hk : 0 < min (B / d) (Q / n)) :
    (Q - min (B / d) (Q / n) * n) +
      (min (B / d) (Q / n) * n + min (B / d) (Q / n) * d) ≠ Q :=
  scalar_aggregation_breaks_quote_conservation h hk

example {r : Request} {p : Preview} (h : propose r = some p) : p = assemble r :=
  accepted_is_assembled h

example {r : Request} {p : Preview} (h : propose r = some p) : AssertionsValid r :=
  accepted_assertions_valid h

example {r : Request} {p : Preview} (h : propose r = some p) :
    p.request.quoteSource = r.quoteSource ∧ p.request.baseSource = r.baseSource :=
  preserves_both_sources h

example {r : Request} {p : Preview} (h : propose r = some p) :
    p.quoteRow.sourceId = r.quoteSource.id ∧ p.quoteRow.sourceRevision = r.quoteSource.revision ∧
    p.quoteRow.currency = r.quoteSource.currency ∧ p.baseRow.sourceId = r.baseSource.id ∧
    p.baseRow.sourceRevision = r.baseSource.revision ∧ p.baseRow.currency = r.baseSource.currency :=
  preserves_independent_source_identities h

example {r : Request} {p : Preview} (h : propose r = some p) :
    p.quoteRow.sourceId ≠ p.baseRow.sourceId := distinct_sources_stay_distinct h

example {r : Request} {p : Preview} (h : propose r = some p) :
    p.quoteRow.currency ≠ p.baseRow.currency := distinct_currencies_stay_distinct h

example {r : Request} {p : Preview} (h : propose r = some p) :
    p.quoteRow.residual + p.quoteRow.reduction = p.quoteRow.original ∧
    p.baseRow.residual + p.baseRow.reduction = p.baseRow.original := accepted_conservation h

example {r : Request} {p : Preview}
    (hne : p.quoteRow.sourceRevision ≠ r.quoteSource.revision) : propose r ≠ some p :=
  mismatched_quote_revision_refused hne

example {r : Request} {p : Preview}
    (hne : p.quoteRow.sourceId ≠ r.quoteSource.id ∨ p.baseRow.sourceId ≠ r.baseSource.id) :
    propose r ≠ some p := substituted_source_refused hne

example {r : Request} (h : r.agreement.validUntil ≤ r.observedAt) : propose r = none :=
  expired_agreement_refused h

example {r : Request} (h : r.observedAt < r.agreement.agreedAt) : propose r = none :=
  future_agreement_refused h

example {r : Request} (h : ¬ (0 < r.agreement.numerator ∧ 0 < r.agreement.denominator ∧
    Nat.gcd r.agreement.numerator r.agreement.denominator = 1)) : propose r = none :=
  noncanonical_rate_refused h

example {r : Request} {p : Preview} (h : propose r = some p) :
    p.admitted = false ∧ p.authenticatedConsent = false ∧ p.debtDischarged = false ∧
    p.accountingPosted = false ∧ p.paymentExecuted = false ∧ p.fxExecuted = false ∧
    p.favorableLegalClassification = false := accepted_no_effects h

example {p : Preview} {now : Nat} (h : now ≠ p.request.observedAt) : verifyPlan p now = false :=
  changed_observation_refused h

example {r : Request} {p : Preview} (h : propose r = some p) :
    r.agreement.numerator * p.baseRow.reduction =
      r.agreement.denominator * p.quoteRow.reduction := accepted_exact h

example {r : Request} {p : Preview} {q b : Nat} (h : propose r = some p)
    (hf : q ≤ r.quoteSource.amount ∧ b ≤ r.baseSource.amount ∧
      r.agreement.numerator * b = r.agreement.denominator * q) :
    q ≤ p.quoteRow.reduction ∧ b ≤ p.baseRow.reduction := accepted_maximum_exact_offset h hf

example {r : Request} {p : Preview}
    (hne : p.baseRow.sourceRevision ≠ r.baseSource.revision) : propose r ≠ some p :=
  mismatched_base_revision_refused hne

example {r r' : Request} {p p' : Preview} (h : propose r = some p) (h' : propose r' = some p')
    (hchanged : r.quoteSource ≠ r'.quoteSource ∨ r.baseSource ≠ r'.baseSource) : p ≠ p' :=
  changed_source_snapshot_changes_preview h h' hchanged

example {r : Request} (h : r.quoteSource.validUntil ≤ r.observedAt ∨
    r.baseSource.validUntil ≤ r.observedAt) : propose r = none := expired_source_refused h

example {r : Request} (h : r.quoteSource.currency = r.baseSource.currency) : propose r = none :=
  same_currency_refused h

example {r : Request} (h : min (r.baseSource.amount / r.agreement.denominator)
    (r.quoteSource.amount / r.agreement.numerator) = 0) : propose r = none := no_exact_offset_refused h
