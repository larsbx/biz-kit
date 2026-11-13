import Lean.Elab.Tactic.Omega
import Lean.Elab.Tactic.RCases

/-!
# SCF ledger and statement obligations

Source basis: a9a1bd1b35055b749181c0797f081c9297118a23, `apps/scf_core`.
This is an unbounded, pure model of validated entries, successful posting,
monotone closure and reversal. Dates and identifiers are natural numbers;
metadata is an opaque value covering the other validated entry fields.
`Account.bucket` is the admitted chart partition, not a proved string parser.

The model retains the implementation's two subtle admission rules: an exact
retry succeeds even after closure, and reversal attributes can override lines.
Cancellation is proved only for a fresh, admitted reversal with exactly swapped
lines. No theorem asserts that there can be only one reversal of an entry.

Statement equations are proved separately for signed account balances in the
admitted partition. They require a zero-sum trial balance for the bilan equation.
Extraction of balances, date filtering, input validation, chart parsing, and
refinement of the Elixir implementation to this model remain unproved.
This does not certify fiscal applicability, persistence or runtime conformance.
-/

namespace BizKitScf

/-- The disjoint groups used by Statements.tcr_of/1 and bilan/2. Class 1
prefixes 10/11/12 are capital; admitted 13/15/16/17/18 are noncurrent debt.
Classes 2 and 3 are assets; classes 4 and 5 split by signed account balance.
There is no admitted 71 or 79 prefix in Chart.accounts/0. -/
inductive Bucket where
  | capital | debt | asset | stock | tiers
  | c60 | c61 | c62 | c63 | c64 | c65 | c66 | c67 | c68 | c69
  | p70 | p72 | p73 | p74 | p75 | p76 | p77 | p78
  deriving DecidableEq, Repr

structure Account where
  bucket : Bucket
  subaccount : Nat
  deriving DecidableEq, Repr

inductive Side where
  | debit | credit
  deriving DecidableEq, Repr

structure Line where
  side : Side
  account : Account
  amount : Nat
  deriving DecidableEq, Repr

def Line.debit (l : Line) : Int := if l.side = .debit then l.amount else 0
def Line.credit (l : Line) : Int := if l.side = .credit then l.amount else 0

def Line.swap (l : Line) : Line :=
  { l with side := match l.side with | .debit => .credit | .credit => .debit }

def debits : List Line → Int
  | [] => 0
  | l :: ls => l.debit + debits ls

def credits : List Line → Int
  | [] => 0
  | l :: ls => l.credit + credits ls

def movement (a : Account) : List Line → Int
  | [] => 0
  | l :: ls => (if l.account = a then l.debit - l.credit else 0) + movement a ls

theorem swapped_debits (ls : List Line) : debits (ls.map Line.swap) = credits ls := by
  induction ls with
  | nil => rfl
  | cons l ls ih =>
    cases l with
    | mk side account amount =>
      cases side <;> simp [debits, credits, Line.debit, Line.credit, Line.swap, ih]

theorem swapped_credits (ls : List Line) : credits (ls.map Line.swap) = debits ls := by
  induction ls with
  | nil => rfl
  | cons l ls ih =>
    cases l with
    | mk side account amount =>
      cases side <;> simp [debits, credits, Line.debit, Line.credit, Line.swap, ih]

theorem swapped_movement (a : Account) (ls : List Line) :
    movement a (ls.map Line.swap) = - movement a ls := by
  induction ls with
  | nil => simp [movement]
  | cons l ls ih =>
    cases l with
    | mk side account amount =>
      cases side <;> by_cases h : account = a <;>
        simp [movement, Line.debit, Line.credit, Line.swap, ih, h] <;> omega

structure Entry where
  id : Nat
  date : Nat
  metadata : String
  lines : List Line
  deriving DecidableEq, Repr

/-- Other field validators are abstracted by the input domain. -/
def Admitted (e : Entry) : Prop :=
  debits e.lines = credits e.lines ∧ 2 ≤ e.lines.length ∧
    ∀ l ∈ e.lines, 0 < l.amount

instance (e : Entry) : Decidable (Admitted e) := by unfold Admitted; infer_instance

def lookup : List Entry → Nat → Option Entry
  | [], _ => none
  | e :: es, id => if e.id = id then some e else lookup es id

structure Ledger where
  entries : List Entry := []
  closedThrough : Option Nat := none
  deriving DecidableEq, Repr

def empty : Ledger := ⟨[], none⟩

def Open (s : Ledger) (date : Nat) : Prop :=
  match s.closedThrough with
  | none => True
  | some through => through < date

instance (s : Ledger) (date : Nat) : Decidable (Open s date) := by
  unfold Open; split <;> infer_instance

def post (s : Ledger) (e : Entry) : Option Ledger :=
  if Admitted e then
    match lookup s.entries e.id with
    | some old => if old = e then some s else none
    | none => if Open s e.date then some { s with entries := e :: s.entries } else none
  else none

def close (s : Ledger) (through : Nat) : Option Ledger :=
  match s.closedThrough with
  | none => some { s with closedThrough := some through }
  | some old =>
    if old ≤ through then some { s with closedThrough := some through } else none

structure ReverseAttrs where
  id : Nat
  date : Nat
  metadata : String
  lines : Option (List Line) := none
  deriving DecidableEq, Repr

def reversalEntry (original : Entry) (attrs : ReverseAttrs) : Entry :=
  ⟨attrs.id, attrs.date, attrs.metadata, attrs.lines.getD (original.lines.map Line.swap)⟩

/-- As in Map.merge/2, caller-supplied lines override generated swapped lines. -/
def reverse (s : Ledger) (id : Nat) (attrs : ReverseAttrs) : Option Ledger :=
  match lookup s.entries id with
  | none => none
  | some original => post s (reversalEntry original attrs)

def Safe (s : Ledger) : Prop := ∀ e ∈ s.entries, Admitted e

def closedEntries (s : Ledger) (through : Nat) : List Entry :=
  s.entries.filter (fun e => e.date ≤ through)

/-- Every already closed prefix is frozen; the closure bound cannot retreat. -/
def PreservesClosed (s t : Ledger) : Prop :=
  ∀ old, s.closedThrough = some old →
    (∃ next, t.closedThrough = some next ∧ old ≤ next) ∧
    ∀ through, through ≤ old → closedEntries t through = closedEntries s through

theorem post_cases (s t : Ledger) (e : Entry) (h : post s e = some t) :
    t = s ∨ (Admitted e ∧ Open s e.date ∧ t = { s with entries := e :: s.entries }) := by
  unfold post at h
  split at h
  · rename_i valid
    split at h
    · split at h
      · cases h; exact Or.inl rfl
      · cases h
    · split at h
      · cases h; exact Or.inr ⟨valid, by assumption, rfl⟩
      · cases h
  · cases h

theorem post_preserves (s t : Ledger) (e : Entry) (hs : Safe s)
    (h : post s e = some t) : Safe t ∧ PreservesClosed s t := by
  rcases post_cases s t e h with rfl | ⟨valid, opened, rfl⟩
  · refine ⟨hs, ?_⟩
    intro old hc
    exact ⟨⟨old, hc, Nat.le_refl _⟩, fun _ _ => rfl⟩
  · constructor
    · intro x hx
      simp only [List.mem_cons] at hx
      rcases hx with rfl | hx
      · exact valid
      · exact hs x hx
    · intro old hc
      refine ⟨⟨old, hc, Nat.le_refl _⟩, ?_⟩
      intro through ht
      have hd : ¬ e.date ≤ through := by
        simp [Open, hc] at opened
        omega
      simp [closedEntries, hd]

theorem close_preserves (s t : Ledger) (through : Nat) (hs : Safe s)
    (h : close s through = some t) : Safe t ∧ PreservesClosed s t := by
  unfold close at h
  split at h
  · rename_i hc
    cases h
    refine ⟨hs, ?_⟩
    intro old he
    simp [hc] at he
  · rename_i old hc
    split at h
    · rename_i monotone
      cases h
      refine ⟨hs, ?_⟩
      intro prior hp
      have same : prior = old := by simp [hc] at hp; omega
      subst prior
      exact ⟨⟨through, rfl, monotone⟩, fun _ _ => rfl⟩
    · cases h

theorem reverse_preserves (s t : Ledger) (id : Nat) (attrs : ReverseAttrs)
    (hs : Safe s) (h : reverse s id attrs = some t) : Safe t ∧ PreservesClosed s t := by
  unfold reverse at h
  split at h
  · cases h
  · exact post_preserves s t _ hs h

inductive Step : Ledger → Ledger → Prop where
  | post (s t : Ledger) (e : Entry) (h : BizKitScf.post s e = some t) : Step s t
  | close (s t : Ledger) (date : Nat) (h : BizKitScf.close s date = some t) : Step s t
  | reverse (s t : Ledger) (id : Nat) (a : ReverseAttrs)
      (h : BizKitScf.reverse s id a = some t) : Step s t

theorem step_preserves {s t : Ledger} (step : Step s t) (hs : Safe s) :
    Safe t ∧ PreservesClosed s t := by
  cases step with
  | post e h => exact post_preserves _ _ e hs h
  | close date h => exact close_preserves _ _ date hs h
  | reverse id a h => exact reverse_preserves _ _ id a hs h

inductive Reachable : Ledger → Prop where
  | empty : Reachable BizKitScf.empty
  | next {s t : Ledger} (prior : Reachable s) (step : Step s t) : Reachable t

theorem reachable_safe {s : Ledger} (h : Reachable s) : Safe s := by
  induction h with
  | empty => simp [Safe, empty]
  | next _ step ih => exact (step_preserves step ih).1

def ledgerDebits (es : List Entry) : Int := (es.map (fun e => debits e.lines)).sum
def ledgerCredits (es : List Entry) : Int := (es.map (fun e => credits e.lines)).sum

theorem admitted_totals (es : List Entry) (h : ∀ e ∈ es, Admitted e) :
    ledgerDebits es = ledgerCredits es := by
  induction es with
  | nil => rfl
  | cons e es ih =>
    have he := (h e (by simp)).1
    have tail := ih (fun x hx => h x (by simp [hx]))
    simp only [ledgerDebits, ledgerCredits, List.map_cons, List.sum_cons] at *
    omega

theorem reachable_balanced {s : Ledger} (h : Reachable s) :
    ledgerDebits s.entries = ledgerCredits s.entries :=
  admitted_totals s.entries (reachable_safe h)

theorem exact_retry (s : Ledger) (e : Entry) (valid : Admitted e)
    (stored : lookup s.entries e.id = some e) : post s e = some s := by
  simp [post, valid, stored]

def ledgerMovement (a : Account) (es : List Entry) : Int :=
  (es.map (fun e => movement a e.lines)).sum

/-- With a fresh ID and an open date, exactly swapped lines are admitted and
cancel the original account-by-account. The supporting metadata is assumed
validated; no uniqueness-of-correction guarantee is asserted. -/
theorem reversal_contract (s : Ledger) (original : Entry) (attrs : ReverseAttrs)
    (found : lookup s.entries original.id = some original)
    (fresh : lookup s.entries attrs.id = none)
    (valid : Admitted original) (opened : Open s attrs.date) (noOverride : attrs.lines = none) :
    reverse s original.id attrs = some { s with entries := reversalEntry original attrs :: s.entries } ∧
    ∀ a, ledgerMovement a (reversalEntry original attrs :: s.entries) =
      ledgerMovement a s.entries - movement a original.lines := by
  have admitted : Admitted (reversalEntry original attrs) := by
    rcases valid with ⟨balanced, length, positive⟩
    simp only [Admitted, reversalEntry, noOverride, Option.getD_none]
    refine ⟨?_, by simpa using length, ?_⟩
    · simpa [swapped_debits, swapped_credits] using balanced.symm
    · intro l hl
      rcases List.mem_map.mp hl with ⟨originalLine, member, rfl⟩
      simpa [Line.swap] using positive originalLine member
  constructor
  · simp only [reverse, found]
    unfold post
    rw [ite_eq_left admitted]
    simp [reversalEntry, fresh, opened]
  · intro a
    simp only [ledgerMovement, List.map_cons, List.sum_cons]
    simp only [reversalEntry, noOverride, Option.getD_none, swapped_movement]
    omega

/-! ## Statement equations

Balances below are signed debit-minus-credit balances *per account* after
aggregation, as required for the class 4/5 sign split. The partition is explicit:
all admitted classes 6/7 occur exactly once in the income statement formula.
-/

structure Balance where
  account : Account
  amount : Int
  deriving DecidableEq, Repr

def group (g : Bucket) (bs : List Balance) : Int :=
  (bs.map (fun b => if b.account.bucket = g then b.amount else 0)).sum

def expenses (bs : List Balance) : Int :=
  group .c60 bs + group .c61 bs + group .c62 bs + group .c63 bs + group .c64 bs +
  group .c65 bs + group .c66 bs + group .c67 bs + group .c68 bs + group .c69 bs

def products (bs : List Balance) : Int :=
  -(group .p70 bs + group .p72 bs + group .p73 bs + group .p74 bs +
    group .p75 bs + group .p76 bs + group .p77 bs + group .p78 bs)

def production (bs : List Balance) : Int :=
  -(group .p70 bs + group .p72 bs + group .p73 bs + group .p74 bs)
def consumption (bs : List Balance) : Int := group .c60 bs + group .c61 bs + group .c62 bs
def valueAdded (bs : List Balance) : Int := production bs - consumption bs
def grossOperating (bs : List Balance) : Int := valueAdded bs - (group .c63 bs + group .c64 bs)
def operating (bs : List Balance) : Int :=
  grossOperating bs - (group .p75 bs + group .p78 bs) - (group .c65 bs + group .c68 bs)
def financial (bs : List Balance) : Int := -group .p76 bs - group .c66 bs
def extraordinary (bs : List Balance) : Int := -group .p77 bs - group .c67 bs
def resultNet (bs : List Balance) : Int :=
  operating bs + financial bs - group .c69 bs + extraordinary bs

theorem income_equation (bs : List Balance) : resultNet bs = products bs - expenses bs := by
  dsimp [resultNet, operating, grossOperating, valueAdded, production, consumption,
    financial, extraordinary, products, expenses]
  omega

def tiersPositive (bs : List Balance) : Int :=
  (bs.map (fun b => if b.account.bucket = .tiers ∧ 0 < b.amount then b.amount else 0)).sum
def tiersNegative (bs : List Balance) : Int :=
  (bs.map (fun b => if b.account.bucket = .tiers ∧ b.amount < 0 then b.amount else 0)).sum

theorem tiers_partition (bs : List Balance) :
    tiersPositive bs + tiersNegative bs = group .tiers bs := by
  induction bs with
  | nil => rfl
  | cons b bs ih =>
    simp only [tiersPositive, tiersNegative, group, List.map_cons, List.sum_cons] at *
    by_cases ht : b.account.bucket = .tiers
    · by_cases hp : 0 < b.amount
      · simp [ht, hp, show ¬ b.amount < 0 by omega]; omega
      · by_cases hn : b.amount < 0
        · simp [ht, hp, hn]; omega
        · have hz : b.amount = 0 := by omega
          simp [ht, hz]; omega
    · simp [ht]; omega

def trialNet (bs : List Balance) : Int := (bs.map Balance.amount).sum

theorem chart_partition (bs : List Balance) :
    trialNet bs = group .capital bs + group .debt bs + group .asset bs +
      group .stock bs + group .tiers bs + expenses bs - products bs := by
  induction bs with
  | nil => rfl
  | cons b bs ih =>
    simp only [trialNet, group, expenses, products, List.map_cons, List.sum_cons] at *
    cases b.account.bucket <;> simp_all <;> omega

def totalAssets (bs : List Balance) : Int := group .asset bs + group .stock bs + tiersPositive bs
def totalLiabilities (bs : List Balance) : Int :=
  -group .capital bs + resultNet bs - group .debt bs - tiersNegative bs

theorem balance_sheet_equation (bs : List Balance) (balanced : trialNet bs = 0) :
    totalAssets bs = totalLiabilities bs := by
  have hp := chart_partition bs
  have ht := tiers_partition bs
  have hi := income_equation bs
  dsimp [totalAssets, totalLiabilities]
  omega

/-- Coverage entry point. Each clause is universally quantified; none is a
bounded sample or a claim that the Elixir implementation refines this model. -/
theorem obligation :
    (∀ s, Reachable s → ledgerDebits s.entries = ledgerCredits s.entries) ∧
    (∀ s t, Reachable s → Step s t → PreservesClosed s t) ∧
    (∀ s e, Admitted e → lookup s.entries e.id = some e → post s e = some s) ∧
    (∀ s original attrs, lookup s.entries original.id = some original →
      lookup s.entries attrs.id = none → Admitted original → Open s attrs.date →
      attrs.lines = none →
      reverse s original.id attrs = some { s with entries := reversalEntry original attrs :: s.entries } ∧
      ∀ a, ledgerMovement a (reversalEntry original attrs :: s.entries) =
        ledgerMovement a s.entries - movement a original.lines) ∧
    (∀ bs, resultNet bs = products bs - expenses bs) ∧
    (∀ bs, trialNet bs = 0 → totalAssets bs = totalLiabilities bs) := by
  exact ⟨fun _ h => reachable_balanced h,
    fun _ _ hs step => (step_preserves step (reachable_safe hs)).2,
    exact_retry, reversal_contract, income_equation, balance_sheet_equation⟩

/-! ## Checked witnesses and negative controls -/

def bank : Account := ⟨.tiers, 512⟩
def capital : Account := ⟨.capital, 101⟩
def opening : Entry := ⟨1, 1, "validated opening", [⟨.debit, bank, 100⟩, ⟨.credit, capital, 100⟩]⟩
def openedLedger : Ledger := ⟨[opening], none⟩
def closedLedger : Ledger := ⟨[opening], some 1⟩
def reversal : ReverseAttrs := ⟨2, 2, "validated correction", none⟩

theorem nonvacuity_witness :
    post empty opening = some openedLedger ∧ close openedLedger 1 = some closedLedger ∧
    post closedLedger opening = some closedLedger ∧
    reverse closedLedger 1 reversal =
      some ⟨[reversalEntry opening reversal, opening], some 1⟩ := by decide

theorem closed_period_refused :
    post closedLedger { opening with id := 2 } = none := by decide

theorem conflicting_retry_refused :
    post openedLedger { opening with metadata := "different supporting document" } = none := by decide

theorem closure_regression_refused : close closedLedger 0 = none := by decide

/-- A removed closure guard would insert a new entry into the frozen prefix. -/
theorem unchecked_post_counterexample :
    closedEntries { closedLedger with entries := { opening with id := 2 } :: closedLedger.entries } 1 ≠
      closedEntries closedLedger 1 := by decide

/-- A removed balance guard would admit unequal debit and credit totals. -/
theorem unchecked_balance_counterexample :
    ledgerDebits [{ opening with lines := [⟨.debit, bank, 100⟩, ⟨.credit, capital, 99⟩] }] ≠
      ledgerCredits [{ opening with lines := [⟨.debit, bank, 100⟩, ⟨.credit, capital, 99⟩] }] := by decide

/-- Balanced replacement lines are legal but need not cancel the original. -/
theorem override_does_not_cancel :
    let attrs := { reversal with lines := some opening.lines }
    reverse closedLedger 1 attrs = some ⟨[reversalEntry opening attrs, opening], some 1⟩ ∧
      movement bank opening.lines + movement bank (reversalEntry opening attrs).lines ≠ 0 := by decide

/-- Single-correction admission is intentionally absent: distinct fresh IDs
can both reverse the same original, making the net bank balance negative. -/
theorem repeated_reversal_counterexample :
    let once : Ledger := ⟨[reversalEntry opening reversal, opening], some 1⟩
    let again := { reversal with id := 3 }
    reverse once 1 again = some ⟨reversalEntry opening again :: once.entries, some 1⟩ ∧
      ledgerMovement bank (reversalEntry opening again :: once.entries) = -100 := by decide

/-- Omitting result allocation from liabilities breaks the bilan equation. -/
theorem missing_result_counterexample :
    let bs := [Balance.mk bank 100, Balance.mk ⟨.p70, 700⟩ (-100)]
    trialNet bs = 0 ∧ totalAssets bs = totalLiabilities bs ∧
      totalAssets bs ≠ (-group .capital bs - group .debt bs - tiersNegative bs) := by decide

end BizKitScf
