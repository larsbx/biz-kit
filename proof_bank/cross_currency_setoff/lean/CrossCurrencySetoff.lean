import Init

/-!
Exact-integer bilateral cross-currency preview mathematics.

All quantities are minor units. `n/d` means quote minor units per base minor
unit. Proofs concern asserted records and arithmetic, not authentic contracts,
current external source history, effective discharge, journal recognition,
payment, foreign-exchange execution, or favorable legal classification.
-/
namespace CrossCurrencySetoff

/-- Positive, reduced rational representation. Currency direction is fixed separately. -/
def Canonical (n d : Nat) : Prop := 0 < n ∧ 0 < d ∧ Nat.Coprime n d

instance (n d : Nat) : Decidable (Canonical n d) := inferInstanceAs
  (Decidable (0 < n ∧ 0 < d ∧ Nat.Coprime n d))

/-- The existing Elixir algorithm, represented with unbounded natural numbers. -/
def multiples (Q B n d : Nat) : Nat := min (B / d) (Q / n)
def quoteReduction (Q B n d : Nat) : Nat := multiples Q B n d * n
def baseReduction (Q B n d : Nat) : Nat := multiples Q B n d * d
def quoteResidual (Q B n d : Nat) : Nat := Q - quoteReduction Q B n d
def baseResidual (Q B n d : Nat) : Nat := B - baseReduction Q B n d

/-- Exact integer valuation without assuming an integer multiplier in advance. -/
def Exact (n d q b : Nat) : Prop := n * b = d * q

def Feasible (Q B n d q b : Nat) : Prop := q ≤ Q ∧ b ≤ B ∧ Exact n d q b

/-- Every exact integer pair has one common multiplier when the rate is canonical. -/
theorem exact_iff_common_multiplier {n d q b : Nat} (h : Canonical n d) :
    Exact n d q b ↔ ∃ k, q = k * n ∧ b = k * d := by
  rcases h with ⟨hn, hd, hcop⟩
  constructor
  · intro he
    have hdvd : d ∣ b := hcop.symm.dvd_of_dvd_mul_left (by
      show d ∣ n * b
      rw [he]
      exact Nat.dvd_mul_right d q)
    rcases hdvd with ⟨k, hk⟩
    have hb : b = k * d := by simpa [Nat.mul_comm] using hk
    have hq : q = k * n := by
      apply Nat.mul_left_cancel hd
      calc
        d * q = n * b := he.symm
        _ = d * (k * n) := by rw [hb]; simp [Nat.mul_comm, Nat.mul_left_comm]
    exact ⟨k, hq, hb⟩
  · rintro ⟨k, rfl, rfl⟩
    simp [Exact, Nat.mul_comm, Nat.mul_left_comm]

/-- A reduced positive rate has only one numerator and denominator for its value. -/
theorem canonical_unique {n d n' d' : Nat} (h : Canonical n d)
    (h' : Canonical n' d') (he : n * d' = n' * d) : n = n' ∧ d = d' := by
  have hnn' : n ∣ n' := h.2.2.dvd_of_dvd_mul_right (by
    rw [← he]
    exact Nat.dvd_mul_right n d')
  have hn'n : n' ∣ n := h'.2.2.dvd_of_dvd_mul_right (by
    rw [he]
    exact Nat.dvd_mul_right n' d)
  have hn : n = n' := Nat.dvd_antisymm hnn' hn'n
  refine ⟨hn, ?_⟩
  apply Nat.mul_left_cancel h.1
  simpa [← hn] using he.symm

theorem quote_reduction_bounded (Q B n d : Nat) (hn : 0 < n) :
    quoteReduction Q B n d ≤ Q := by
  apply (Nat.le_div_iff_mul_le hn).mp
  exact Nat.min_le_right _ _

theorem base_reduction_bounded (Q B n d : Nat) (hd : 0 < d) :
    baseReduction Q B n d ≤ B := by
  apply (Nat.le_div_iff_mul_le hd).mp
  exact Nat.min_le_left _ _

theorem quote_conservation (Q B n d : Nat) (hn : 0 < n) :
    quoteResidual Q B n d + quoteReduction Q B n d = Q := by
  exact Nat.sub_add_cancel (quote_reduction_bounded Q B n d hn)

theorem base_conservation (Q B n d : Nat) (hd : 0 < d) :
    baseResidual Q B n d + baseReduction Q B n d = B := by
  exact Nat.sub_add_cancel (base_reduction_bounded Q B n d hd)

theorem residuals_nonnegative (Q B n d : Nat) :
    0 ≤ quoteResidual Q B n d ∧ 0 ≤ baseResidual Q B n d :=
  ⟨Nat.zero_le _, Nat.zero_le _⟩

/-- Integer interpretation confirms that natural-number subtraction did not hide underflow. -/
theorem integer_residuals (Q B n d : Nat) (hn : 0 < n) (hd : 0 < d) :
    (quoteResidual Q B n d : Int) = (Q : Int) - (quoteReduction Q B n d : Int) ∧
    (baseResidual Q B n d : Int) = (B : Int) - (baseReduction Q B n d : Int) := by
  have hq := quote_conservation Q B n d hn
  have hb := base_conservation Q B n d hd
  omega

theorem proposed_exact (Q B n d : Nat) :
    Exact n d (quoteReduction Q B n d) (baseReduction Q B n d) := by
  simp [Exact, quoteReduction, baseReduction, Nat.mul_comm, Nat.mul_left_comm]

theorem proposed_feasible (Q B n d : Nat) (h : Canonical n d) :
    Feasible Q B n d (quoteReduction Q B n d) (baseReduction Q B n d) :=
  ⟨quote_reduction_bounded Q B n d h.1,
   base_reduction_bounded Q B n d h.2.1, proposed_exact Q B n d⟩

/-- A multiplier is feasible exactly when it is at most the computed maximum. -/
theorem multiplier_feasible_iff {Q B n d k : Nat} (hn : 0 < n) (hd : 0 < d) :
    k * n ≤ Q ∧ k * d ≤ B ↔ k ≤ multiples Q B n d := by
  simp only [multiples, Nat.le_min, Nat.le_div_iff_mul_le hn, Nat.le_div_iff_mul_le hd]
  exact and_comm

/-- Maximality ranges over all exact integer pairs, not merely a preselected family. -/
theorem maximum_exact_offset {Q B n d q b : Nat} (h : Canonical n d)
    (hf : Feasible Q B n d q b) :
    q ≤ quoteReduction Q B n d ∧ b ≤ baseReduction Q B n d := by
  obtain ⟨k, hq, hb⟩ := (exact_iff_common_multiplier h).mp hf.2.2
  have hk : k ≤ multiples Q B n d :=
    (multiplier_feasible_iff h.1 h.2.1).mp (by simpa [← hq, ← hb] using And.intro hf.1 hf.2.1)
  simpa [hq, hb, quoteReduction, baseReduction] using
    And.intro (Nat.mul_le_mul_right n hk) (Nat.mul_le_mul_right d hk)

/-- Any attempt to increase either reduction strictly violates feasibility or exactness. -/
theorem no_larger_exact_offset {Q B n d q b : Nat} (h : Canonical n d)
    (larger : quoteReduction Q B n d < q ∨ baseReduction Q B n d < b) :
    ¬ Feasible Q B n d q b := by
  intro hf
  have hm := maximum_exact_offset h hf
  omega

/-- No positive exact pair exists exactly when the preview refuses a zero multiplier. -/
theorem refusal_iff_no_positive_exact {Q B n d : Nat} (h : Canonical n d) :
    multiples Q B n d = 0 ↔
      ¬ ∃ q b, 0 < q ∧ 0 < b ∧ Feasible Q B n d q b := by
  constructor
  · intro hk
    rintro ⟨q, b, hq, _, hf⟩
    have hm := (maximum_exact_offset h hf).1
    simp [quoteReduction, hk] at hm
    omega
  · intro hnone
    by_cases hk : multiples Q B n d = 0
    · exact hk
    apply False.elim
    have hp : 0 < multiples Q B n d := Nat.pos_of_ne_zero hk
    exact hnone ⟨quoteReduction Q B n d, baseReduction Q B n d,
      Nat.mul_pos hp h.1, Nat.mul_pos hp h.2.1, proposed_feasible Q B n d h⟩

/-- At least one currency lacks the capacity for one additional exact rate quantum. -/
theorem residual_exhaustion {Q B n d : Nat} (h : Canonical n d) :
    quoteResidual Q B n d < n ∨ baseResidual Q B n d < d := by
  by_cases hr : quoteResidual Q B n d < n ∨ baseResidual Q B n d < d
  · exact hr
  apply False.elim
  have hq := quote_conservation Q B n d h.1
  have hb := base_conservation Q B n d h.2.1
  have hq' : (multiples Q B n d + 1) * n ≤ Q := by
    simp only [Nat.add_mul, Nat.one_mul]
    simp only [quoteReduction] at hq
    omega
  have hb' : (multiples Q B n d + 1) * d ≤ B := by
    simp only [Nat.add_mul, Nat.one_mul]
    simp only [baseReduction] at hb
    omega
  have := (multiplier_feasible_iff h.1 h.2.1).mp ⟨hq', hb'⟩
  omega

/-- Every exact quote reduction is a multiple of n; fractional quote rounding is impossible. -/
theorem exact_quote_divisible {n d q b : Nat} (h : Canonical n d) (he : Exact n d q b) :
    n ∣ q := by
  obtain ⟨k, hq, _⟩ := (exact_iff_common_multiplier h).mp he
  exact ⟨k, by simpa [Nat.mul_comm] using hq⟩

/-- Every exact base reduction is a multiple of d; fractional base rounding is impossible. -/
theorem exact_base_divisible {n d q b : Nat} (h : Canonical n d) (he : Exact n d q b) :
    d ∣ b := by
  obtain ⟨k, _, hb⟩ := (exact_iff_common_multiplier h).mp he
  exact ⟨k, by simpa [Nat.mul_comm] using hb⟩

end CrossCurrencySetoff

namespace CrossCurrencySetoff

def maxMinor : Nat := 9007199254740991

theorem reduction_machine_bound {Q B n d : Nat} (h : Canonical n d)
    (hQ : Q ≤ maxMinor) (hB : B ≤ maxMinor) :
    quoteReduction Q B n d ≤ maxMinor ∧ baseReduction Q B n d ≤ maxMinor :=
  ⟨Nat.le_trans (quote_reduction_bounded Q B n d h.1) hQ,
   Nat.le_trans (base_reduction_bounded Q B n d h.2.1) hB⟩

/-- Keeping the quote residual while adding a positive base reduction into its total is invalid. -/
theorem scalar_aggregation_breaks_quote_conservation {Q B n d : Nat}
    (h : Canonical n d) (hk : 0 < multiples Q B n d) :
    quoteResidual Q B n d + (quoteReduction Q B n d + baseReduction Q B n d) ≠ Q := by
  have hc := quote_conservation Q B n d h.1
  have hb : 0 < baseReduction Q B n d := Nat.mul_pos hk h.2.1
  omega

/-- All of these fields are host assertions; there is no authentication premise. -/
structure Source where
  id : String
  revision : Nat
  currency : String
  amount : Nat
  debtor : String
  creditor : String
  evidenceRef : String
  validUntil : Nat
  hostDeclaredEligible : Bool
  deriving DecidableEq, Repr

structure Agreement where
  numerator : Nat
  denominator : Nat
  baseCurrency : String
  quoteCurrency : String
  agreedAt : Nat
  validUntil : Nat
  evidenceRef : String
  agreementRef : String
  deriving DecidableEq, Repr

structure Request where
  quoteSource : Source
  baseSource : Source
  agreement : Agreement
  intentId : String
  observedAt : Nat
  deriving DecidableEq, Repr

structure Reduction where
  sourceId : String
  sourceRevision : Nat
  currency : String
  original : Nat
  reduction : Nat
  residual : Nat
  deriving DecidableEq, Repr

structure Preview where
  request : Request
  quoteRow : Reduction
  baseRow : Reduction
  admitted : Bool
  authenticatedConsent : Bool
  debtDischarged : Bool
  accountingPosted : Bool
  paymentExecuted : Bool
  fxExecuted : Bool
  favorableLegalClassification : Bool
  deriving DecidableEq, Repr

/-- The semantic guard abstracts public-ID/ISO syntax checks, which remain Elixir obligations. -/
def SourceAssertions (s : Source) (now : Nat) : Prop :=
  s.id ≠ "" ∧ s.debtor ≠ "" ∧ s.creditor ≠ "" ∧ s.debtor ≠ s.creditor ∧
  0 < s.amount ∧ s.amount ≤ maxMinor ∧ 0 < s.revision ∧ s.revision ≤ maxMinor ∧
  s.evidenceRef ≠ "" ∧ now < s.validUntil ∧ s.hostDeclaredEligible = true

instance (s : Source) (now : Nat) : Decidable (SourceAssertions s now) :=
  inferInstanceAs (Decidable (_ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _))

def AssertionsValid (r : Request) : Prop :=
  SourceAssertions r.quoteSource r.observedAt ∧
  SourceAssertions r.baseSource r.observedAt ∧
  r.quoteSource.id ≠ r.baseSource.id ∧
  r.quoteSource.debtor = r.baseSource.creditor ∧
  r.quoteSource.creditor = r.baseSource.debtor ∧
  r.quoteSource.currency ≠ r.baseSource.currency ∧
  r.agreement.quoteCurrency = r.quoteSource.currency ∧
  r.agreement.baseCurrency = r.baseSource.currency ∧
  Canonical r.agreement.numerator r.agreement.denominator ∧
  r.agreement.numerator ≤ maxMinor ∧ r.agreement.denominator ≤ maxMinor ∧
  r.agreement.agreedAt ≤ r.observedAt ∧ r.observedAt < r.agreement.validUntil ∧
  r.agreement.evidenceRef ≠ "" ∧ r.agreement.agreementRef ≠ "" ∧
  r.intentId ≠ "" ∧ r.intentId ≠ r.quoteSource.id ∧ r.intentId ≠ r.baseSource.id

instance (r : Request) : Decidable (AssertionsValid r) :=
  inferInstanceAs (Decidable (_ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _ ∧ _))

def sourceReduction (s : Source) (reduction : Nat) : Reduction :=
  ⟨s.id, s.revision, s.currency, s.amount, reduction, s.amount - reduction⟩

def assemble (r : Request) : Preview :=
  { request := r
    quoteRow := sourceReduction r.quoteSource (quoteReduction r.quoteSource.amount r.baseSource.amount
      r.agreement.numerator r.agreement.denominator)
    baseRow := sourceReduction r.baseSource (baseReduction r.quoteSource.amount r.baseSource.amount
      r.agreement.numerator r.agreement.denominator)
    admitted := false
    authenticatedConsent := false
    debtDischarged := false
    accountingPosted := false
    paymentExecuted := false
    fxExecuted := false
    favorableLegalClassification := false }

/-- Pure assertion-shape/freshness gate. It does not query authoritative source history. -/
def propose (r : Request) : Option Preview :=
  if AssertionsValid r then
    if multiples r.quoteSource.amount r.baseSource.amount
        r.agreement.numerator r.agreement.denominator = 0 then none
    else some (assemble r)
  else none

def verifyPlan (p : Preview) (now : Nat) : Bool :=
  decide (propose { p.request with observedAt := now } = some p)

theorem accepted_is_assembled {r : Request} {p : Preview} (h : propose r = some p) :
    p = assemble r := by
  unfold propose at h
  split at h
  · split at h
    · contradiction
    · exact Option.some.inj h |>.symm
  · contradiction

theorem accepted_assertions_valid {r : Request} {p : Preview} (h : propose r = some p) :
    AssertionsValid r := by
  unfold propose at h
  split at h
  · assumption
  · contradiction

/-- Both complete original source records remain in the preview, in their original roles. -/
theorem preserves_both_sources {r : Request} {p : Preview} (h : propose r = some p) :
    p.request.quoteSource = r.quoteSource ∧ p.request.baseSource = r.baseSource := by
  rw [accepted_is_assembled h]
  exact ⟨rfl, rfl⟩

/-- Both rows retain independent source IDs, revisions and currencies. -/
theorem preserves_independent_source_identities {r : Request} {p : Preview}
    (h : propose r = some p) :
    p.quoteRow.sourceId = r.quoteSource.id ∧ p.quoteRow.sourceRevision = r.quoteSource.revision ∧
    p.quoteRow.currency = r.quoteSource.currency ∧
    p.baseRow.sourceId = r.baseSource.id ∧ p.baseRow.sourceRevision = r.baseSource.revision ∧
    p.baseRow.currency = r.baseSource.currency := by
  rw [accepted_is_assembled h]
  exact ⟨rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem distinct_sources_stay_distinct {r : Request} {p : Preview} (h : propose r = some p) :
    p.quoteRow.sourceId ≠ p.baseRow.sourceId := by
  have hv := (accepted_assertions_valid h).2.2.1
  rw [accepted_is_assembled h]
  exact hv

theorem distinct_currencies_stay_distinct {r : Request} {p : Preview} (h : propose r = some p) :
    p.quoteRow.currency ≠ p.baseRow.currency := by
  have hv := (accepted_assertions_valid h).2.2.2.2.2.1
  rw [accepted_is_assembled h]
  exact hv

theorem accepted_conservation {r : Request} {p : Preview} (h : propose r = some p) :
    p.quoteRow.residual + p.quoteRow.reduction = p.quoteRow.original ∧
    p.baseRow.residual + p.baseRow.reduction = p.baseRow.original := by
  have hc := (accepted_assertions_valid h).2.2.2.2.2.2.2.2.1
  rw [accepted_is_assembled h]
  exact ⟨quote_conservation _ _ _ _ hc.1, base_conservation _ _ _ _ hc.2.1⟩

/-- A revised source cannot be substituted while retaining the previous reduction row. -/
theorem mismatched_quote_revision_refused {r : Request} {p : Preview}
    (hne : p.quoteRow.sourceRevision ≠ r.quoteSource.revision) : propose r ≠ some p := by
  intro h
  exact hne (preserves_independent_source_identities h).2.1

/-- Replacing either ordered source identity cannot retain the previous preview. -/
theorem substituted_source_refused {r : Request} {p : Preview}
    (hne : p.quoteRow.sourceId ≠ r.quoteSource.id ∨ p.baseRow.sourceId ≠ r.baseSource.id) :
    propose r ≠ some p := by
  intro h
  have hi := preserves_independent_source_identities h
  rcases hne with hq | hb
  · exact hq hi.1
  · exact hb hi.2.2.2.1

theorem expired_agreement_refused {r : Request}
    (hexpired : r.agreement.validUntil ≤ r.observedAt) : propose r = none := by
  have hv : ¬ AssertionsValid r := by
    intro h
    have := h.2.2.2.2.2.2.2.2.2.2.2.2.1
    omega
  simp [propose, hv]

theorem future_agreement_refused {r : Request}
    (hfuture : r.observedAt < r.agreement.agreedAt) : propose r = none := by
  have hv : ¬ AssertionsValid r := by
    intro h
    have := h.2.2.2.2.2.2.2.2.2.2.2.1
    omega
  simp [propose, hv]

theorem noncanonical_rate_refused {r : Request}
    (hbad : ¬ Canonical r.agreement.numerator r.agreement.denominator) : propose r = none := by
  have hv : ¬ AssertionsValid r := fun h => hbad h.2.2.2.2.2.2.2.2.1
  simp [propose, hv]

theorem accepted_no_effects {r : Request} {p : Preview} (h : propose r = some p) :
    p.admitted = false ∧ p.authenticatedConsent = false ∧ p.debtDischarged = false ∧
    p.accountingPosted = false ∧ p.paymentExecuted = false ∧ p.fxExecuted = false ∧
    p.favorableLegalClassification = false := by
  rw [accepted_is_assembled h]
  exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- Revalidation at another observation time cannot equal the old full preview. -/
theorem changed_observation_refused {p : Preview} {now : Nat}
    (hne : now ≠ p.request.observedAt) : verifyPlan p now = false := by
  apply Bool.eq_false_iff.mpr
  intro hv
  have hp : propose { p.request with observedAt := now } = some p := by
    simpa [verifyPlan] using hv
  have ha := accepted_is_assembled hp
  have he := congrArg (fun z : Preview => z.request.observedAt) ha
  exact hne he.symm

end CrossCurrencySetoff

namespace CrossCurrencySetoff

/-- Link successful preview rows directly to the proved exact-rational valuation. -/
theorem accepted_exact {r : Request} {p : Preview} (h : propose r = some p) :
    r.agreement.numerator * p.baseRow.reduction =
      r.agreement.denominator * p.quoteRow.reduction := by
  rw [accepted_is_assembled h]
  exact proposed_exact _ _ _ _

/-- Every other feasible exact pair is bounded by both successful preview rows. -/
theorem accepted_maximum_exact_offset {r : Request} {p : Preview} {q b : Nat}
    (h : propose r = some p)
    (hf : q ≤ r.quoteSource.amount ∧ b ≤ r.baseSource.amount ∧
      r.agreement.numerator * b = r.agreement.denominator * q) :
    q ≤ p.quoteRow.reduction ∧ b ≤ p.baseRow.reduction := by
  have hc := (accepted_assertions_valid h).2.2.2.2.2.2.2.2.1
  rw [accepted_is_assembled h]
  exact maximum_exact_offset hc hf

theorem mismatched_base_revision_refused {r : Request} {p : Preview}
    (hne : p.baseRow.sourceRevision ≠ r.baseSource.revision) : propose r ≠ some p := by
  intro h
  exact hne (preserves_independent_source_identities h).2.2.2.2.1

/-- Even same-total replacement or revision/evidence changes alter the complete preview. -/
theorem changed_source_snapshot_changes_preview {r r' : Request} {p p' : Preview}
    (h : propose r = some p) (h' : propose r' = some p')
    (hchanged : r.quoteSource ≠ r'.quoteSource ∨ r.baseSource ≠ r'.baseSource) : p ≠ p' := by
  intro he
  have hi := preserves_both_sources h
  have hi' := preserves_both_sources h'
  rw [he] at hi
  rcases hchanged with hq | hb
  · exact hq (hi.1.symm.trans hi'.1)
  · exact hb (hi.2.symm.trans hi'.2)

theorem expired_source_refused {r : Request}
    (hexpired : r.quoteSource.validUntil ≤ r.observedAt ∨
      r.baseSource.validUntil ≤ r.observedAt) : propose r = none := by
  have hv : ¬ AssertionsValid r := by
    intro h
    have hq := h.1.2.2.2.2.2.2.2.2.2.1
    have hb := h.2.1.2.2.2.2.2.2.2.2.2.1
    omega
  simp [propose, hv]

theorem same_currency_refused {r : Request}
    (hsame : r.quoteSource.currency = r.baseSource.currency) : propose r = none := by
  have hv : ¬ AssertionsValid r := fun h => h.2.2.2.2.2.1 hsame
  simp [propose, hv]

theorem no_exact_offset_refused {r : Request}
    (hzero : min (r.baseSource.amount / r.agreement.denominator)
      (r.quoteSource.amount / r.agreement.numerator) = 0) : propose r = none := by
  simp only [propose, multiples, hzero, ↓reduceIte]
  split <;> rfl

end CrossCurrencySetoff
