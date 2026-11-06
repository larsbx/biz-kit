import Std.Tactic

/-! Specification of the pilot's measurement/export rules, not a proof of Python,
JSON parsing, source truth, source authentication, hash injectivity or live authorization.
All time units are whole seconds from a common epoch; amounts use signed integers.
No axioms, sorry, native_decide or floating-point arithmetic are introduced. -/
namespace MerchantPilot

structure RevisionKey where
  source : Nat
  owner : Nat
  record : Nat
  revision : Nat
  deriving DecidableEq, Repr

theorem revision_binding (a b : RevisionKey) (h : a = b) :
    a.source = b.source ∧ a.owner = b.owner ∧ a.record = b.record ∧ a.revision = b.revision := by
  cases h
  exact ⟨rfl, rfl, rfl, rfl⟩

def requestAdmitted (qualified duplicate sharingAtQualification retention scope : Bool) : Bool :=
  qualified && !duplicate && sharingAtQualification && retention && scope

theorem duplicate_excluded (q sharing retention scope : Bool) :
    requestAdmitted q true sharing retention scope = false := by
  simp [requestAdmitted]

theorem consent_required (q d retention scope : Bool) :
    requestAdmitted q d false retention scope = false := by
  simp [requestAdmitted]

theorem retention_required (q d sharing scope : Bool) :
    requestAdmitted q d sharing false scope = false := by
  simp [requestAdmitted]

inductive Bucket where
  | earlyWithdrawal | incomplete | mature
  deriving DecidableEq, Repr

def early (qualified : Nat) (withdrawal : Option Nat) (window : Nat) : Bool :=
  match withdrawal with
  | none => false
  | some at => decide (at < qualified + window)

def bucket (qualified now : Nat) (withdrawal : Option Nat) (window : Nat) : Bucket :=
  if early qualified withdrawal window then .earlyWithdrawal
  else if qualified + window ≤ now then .mature else .incomplete

theorem early_never_denominator (q now w at : Nat) (h : at < q + w) :
    bucket q now (some at) w = .earlyWithdrawal := by
  simp [bucket, early, h]

theorem recent_never_denominator (q now w : Nat) (endAt : Option Nat)
    (notEarly : early q endAt w = false) (recent : now < q + w) :
    bucket q now endAt w = .incomplete := by
  simp [bucket, notEarly, Nat.not_le.mpr recent]

theorem mature_at_boundary (q w : Nat) (endAt : Option Nat)
    (notEarly : early q endAt w = false) :
    bucket q (q + w) endAt w = .mature := by
  simp [bucket, notEarly]

structure Quote where
  key : RevisionKey
  issued : Nat
  expires : Nat
  withdrawn : Option Nat
  qualified : Bool
  deriving DecidableEq, Repr

def beforeEnd (endAt : Option Nat) (at : Nat) : Prop :=
  match endAt with | none => True | some t => at < t
instance (e : Option Nat) (at : Nat) : Decidable (beforeEnd e at) := by
  cases e <;> unfold beforeEnd <;> infer_instance

def Actionable (q : Quote) (requestEnd : Option Nat) (at : Nat) : Prop :=
  q.qualified = true ∧ q.issued ≤ at ∧ at < q.expires ∧
  beforeEnd q.withdrawn at ∧ beforeEnd requestEnd at
instance (q : Quote) (e : Option Nat) (at : Nat) : Decidable (Actionable q e at) := by
  unfold Actionable
  infer_instance

def acceptanceAllowed (q : Quote) (bound : RevisionKey) (e : Option Nat) (at : Nat)
    (revalidated : Bool) : Bool := decide (bound = q.key ∧ Actionable q e at ∧ revalidated = true)

theorem acceptance_exact_revision (q : Quote) (bound : RevisionKey) (e : Option Nat)
    (at : Nat) (rv : Bool) (h : acceptanceAllowed q bound e at rv = true) :
    bound = q.key ∧ Actionable q e at ∧ rv = true := by
  exact of_decide_eq_true h

theorem expiry_rejected (q : Quote) (key : RevisionKey) (e : Option Nat) (at : Nat)
    (rv : Bool) (h : q.expires ≤ at) : acceptanceAllowed q key e at rv = false := by
  simp only [acceptanceAllowed, decide_eq_false_iff_not]
  intro valid
  have := valid.2.1.2.2.1
  omega

theorem withdrawal_rejected (q : Quote) (key : RevisionKey) (e : Option Nat) (at endAt : Nat)
    (rv : Bool) (hw : q.withdrawn = some endAt) (h : endAt ≤ at) :
    acceptanceAllowed q key e at rv = false := by
  simp only [acceptanceAllowed, decide_eq_false_iff_not]
  intro valid
  have stop := valid.2.1.2.2.2.1
  simp [beforeEnd, hw] at stop
  omega

def supersede (q : Quote) (at : Nat) : Quote :=
  {q with withdrawn := some (match q.withdrawn with | none => at | some old => min old at)}

theorem supersession_never_extends (q : Quote) (issued at : Nat) (e : Option Nat)
    (h : Actionable (supersede q issued) e at) : Actionable q e at := by
  rcases h with ⟨qualified, started, expires, stop, requestStop⟩
  refine ⟨qualified, started, expires, ?_, requestStop⟩
  cases hw : q.withdrawn with
  | none => simp [beforeEnd, hw]
  | some old =>
    simp [supersede, beforeEnd, hw] at stop
    simp [beforeEnd, hw]
    omega

def pool (complete : Bool) (items : List (Option Int)) : Option Int :=
  if complete then items.foldr (fun x acc => do return (← x) + (← acc)) (some 0) else none

theorem incomplete_cost_unknown (items : List (Option Int)) : pool false items = none := by
  rfl

theorem confirmed_empty_cost_zero : pool true [] = some 0 := by rfl

theorem unknown_expense_unknown (xs : List (Option Int)) (h : none ∈ xs) : pool true xs = none := by
  induction xs with
  | nil => simp at h
  | cons x xs ih =>
    simp only [List.mem_cons] at h
    rcases h with hx | ht
    · subst x; simp [pool]
    · have tail := ih ht
      have tailFold : xs.foldr (fun x acc => do return (← x) + (← acc)) (some 0) = none := by
        simpa [pool] using tail
      cases x <;> simp [pool, tailFold]

structure Margins where
  merchant : Int
  servicingStore : Int
  platform : Int
  deriving DecidableEq, Repr

def margins (gross refund storeFee platformFee merchantCost storeCost platformCost : Int) : Margins :=
  ⟨gross - refund - storeFee - platformFee - merchantCost,
   storeFee - storeCost, platformFee - platformCost⟩

theorem contribution_conservation (g r sf pf mc sc pc : Int) :
    let m := margins g r sf pf mc sc pc
    m.merchant + m.servicingStore + m.platform = g - r - mc - sc - pc := by
  dsimp [margins]
  omega

theorem full_refund_retains_costs (g mc sc pc : Int) :
    margins g g 0 0 mc sc pc = ⟨-mc, -sc, -pc⟩ := by
  simp [margins]

theorem refund_reduces_only_supplier (g r sf pf mc sc pc extra : Int) :
    (margins g (r + extra) sf pf mc sc pc).merchant =
      (margins g r sf pf mc sc pc).merchant - extra ∧
    (margins g (r + extra) sf pf mc sc pc).servicingStore =
      (margins g r sf pf mc sc pc).servicingStore ∧
    (margins g (r + extra) sf pf mc sc pc).platform =
      (margins g r sf pf mc sc pc).platform := by
  dsimp [margins]
  omega

def reportedMargin (reconciled : Bool) (revenue cost : Option Int) : Option Int :=
  if reconciled then do return (← revenue) - (← cost) else none

theorem unknown_cost_withholds (closed : Bool) (revenue : Option Int) :
    reportedMargin closed revenue none = none := by
  cases closed <;> cases revenue <;> rfl

theorem unknown_revenue_withholds (closed : Bool) (cost : Option Int) :
    reportedMargin closed none cost = none := by
  cases closed <;> rfl

theorem unreconciled_withholds (r c : Option Int) : reportedMargin false r c = none := by rfl

def cohortMargin (closed : Bool) (orders : List (Option Int)) (unallocated : Option Int) : Option Int :=
  if closed then do return (← pool true orders) - (← unallocated) else none

theorem unknown_unallocated_withholds (closed : Bool) (xs : List (Option Int)) :
    cohortMargin closed xs none = none := by
  cases closed <;> simp [cohortMargin]; cases pool true xs <;> rfl

theorem missing_order_withholds (closed : Bool) (xs : List (Option Int)) (overhead : Option Int)
    (missing : none ∈ xs) : cohortMargin closed xs overhead = none := by
  cases closed <;> simp [cohortMargin, unknown_expense_unknown xs missing]

def coverageComplete (cutoff : Nat) (heads : List Nat) : Bool := heads.all (fun h => decide (cutoff ≤ h))

theorem stale_source_rejected (cutoff head : Nat) (rest : List Nat) (stale : head < cutoff) :
    coverageComplete cutoff (head :: rest) = false := by
  simp [coverageComplete, Nat.not_le.mpr stale]

-- Typed currencies prevent mixing buckets in this model. Python checks the runtime labels.
inductive Currency where | USD | JPY deriving DecidableEq, Repr
structure Amount (currency : Currency) where
  minor : Int
  deriving DecidableEq, Repr

def addAmount {c : Currency} (a b : Amount c) : Amount c := ⟨a.minor + b.minor⟩

end MerchantPilot
