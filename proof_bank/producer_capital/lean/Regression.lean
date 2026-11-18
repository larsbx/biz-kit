import Capital

open ProducerCapital

namespace CapitalRegression

def position : Position := ⟨12, 3, 2⟩

def project : Project := ⟨4, [.producer, .pool, .pool, .investor 71], 0, 840, 4, position⟩

def initial : State :=
  { projects := fun id => if id = 2 || id = 3 then project else ⟨0, [], 0, 840, 0, ⟨0, 0, 0⟩⟩
    coop := ⟨8, 11⟩ }

def grants : Nat → Option Grant
  | 1 => some ⟨.projectAuthority 2, 31⟩
  | 2 => some ⟨.holder 2 .producer, 32⟩
  | 3 => some ⟨.holder 2 .pool, 33⟩
  | 4 => some ⟨.appraiser 2, 34⟩
  | 5 => some ⟨.projectObserver 2, 35⟩
  | 6 => some ⟨.revoker, 36⟩
  | 7 => some ⟨.coopAuthority .membership, 37⟩
  | 8 => some ⟨.coopObserver .membership, 38⟩
  | 9 => some ⟨.coopAuthority .optionalInvestment, 39⟩
  | 10 => some ⟨.coopObserver .optionalInvestment, 40⟩
  | 11 => some ⟨.holder 2 (.investor 71), 41⟩
  | _ => none

def purchase (tx source version : Nat) (serials : List Nat) : Request :=
  ⟨tx, .purchase source 70 1 2 3 ⟨2, version, .pool, serials, 840, 7 * serials.length, .cash⟩⟩

def fixture (r : Request) : Context :=
  { now := 10
    grant := grants
    signed := fun _ request => decide (request = r)
    valuation := fun id => match r.action with
      | .purchase _ quote _ _ _ terms =>
        if id = quote then some ⟨terms.project, terms.version, terms.currency, 7, 8, 10, 4⟩ else none
      | _ => none
    observation := fun source => match r.action.effect with
      | some (id, effect) => if source = id then some ⟨match effect with
          | .coopDischarge .membership _ => 8
          | .coopDischarge .optionalInvestment _ => 10
          | _ => 5, effect⟩ else none
      | none => none
    allow := fun _ _ => true
    allocationAllowed := fun _ _ _ => true
    distributionSolvent := fun _ _ _ => true }

def execute (s : State) (r : Request) : Option State :=
  step (fixture r) s r

def acceptedSale : Option State := execute initial (purchase 1 80 0 [1, 2])

def profit (tx source version : Nat) (net : Int) (loss : List Allocation := []) : Request :=
  ⟨tx, .earnings source 1 2 version net loss⟩

def payout (tx source version : Nat) (plan : List Allocation)
    (p : Position := position) (asOf : Nat := 10) : Request :=
  ⟨tx, .distribute source 1 2 version p asOf plan⟩

def coopDebit (tx source : Nat) (account : CoopClass) (amount : Nat) : Request :=
  ⟨tx, .coopDischarge source (if account = .membership then 7 else 9) account amount⟩

def rejected (ctx : Context) (s : State) (r : Request) : Bool :=
  (step ctx s r).isNone

def cases : List (String × Bool) := [
  ("exact serials transfer and other capital accounts stay isolated",
    acceptedSale.any fun s => (s.projects 2).owners == [.producer, .producer, .producer, .investor 71] &&
      (s.projects 2).issued == 4 && s.projects 3 == project && s.coop == initial.coop),
  ("both commit orderings reject a competing stale snapshot with fresh identifiers",
    let a := purchase 1 80 0 [1]
    let b := purchase 2 81 0 [2]
    (execute initial a).any (fun s => (execute s b).isNone) &&
    (execute initial b).any (fun s => (execute s a).isNone)),
  ("overlapping serial remains unsellable with fresh revision, valuation and identifiers",
    acceptedSale.any fun s => (execute s (purchase 2 81 1 [2])).isNone),
  ("duplicate and out-of-range serials are rejected",
    (execute initial (purchase 1 80 0 [1, 1])).isNone &&
    (execute initial (purchase 1 80 0 [7])).isNone),
  ("expired and future appraisals are rejected",
    let r := purchase 1 80 0 [1]
    let c := fixture r
    rejected { c with now := 11 } initial r && rejected { c with now := 7 } initial r),
  ("wrong project, version, currency and price appraisals are rejected",
    let r := purchase 1 80 0 [1]
    let c := fixture r
    let v : Valuation := ⟨2, 0, 840, 7, 8, 10, 4⟩
    ([{v with project := 3}, {v with version := 1}, {v with currency := 978},
      {v with perUnit := 8}]).all fun other => rejected {c with valuation := fun _ => some other} initial r),
  ("missing seller signature and self-attested appraisal or consideration are rejected",
    let r := purchase 1 80 0 [1]
    let c := fixture r
    rejected { c with signed := fun id _ => id != 3 } initial r &&
    rejected { c with grant := update grants 4 (some ⟨.appraiser 2, 33⟩) } initial r &&
    rejected { c with grant := update grants 5 (some ⟨.projectObserver 2, 32⟩) } initial r),
  ("forged ownership is rejected even with matching signed sale evidence",
    (execute initial (purchase 1 80 0 [3])).isNone),
  ("consideration attested to a different unit or settlement kind is rejected",
    let r := purchase 1 80 0 [1]
    let c := fixture r
    let wrongUnit := fixture (purchase 1 80 0 [2])
    let barter : Purchase := ⟨2, 0, .pool, [1], 840, 7, .barter⟩
    rejected { c with observation := wrongUnit.observation } initial r &&
    rejected { c with observation := fun _ => some ⟨5, .sale barter⟩ } initial r),
  ("live revocation invalidates a previously signed seller grant",
    (execute initial ⟨9, .revoke 6 3⟩).any fun s =>
      s.revoked 3 && (execute s (purchase 1 80 0 [1])).isNone),
  ("global transaction replay is rejected under another effect and a fresh source",
    acceptedSale.any fun s => (execute s (coopDebit 1 81 .membership 2)).isNone),
  ("global source replay is rejected across project and both cooperative classes",
    acceptedSale.any fun s =>
      (execute s (coopDebit 2 80 .membership 2)).isNone &&
      (execute s (coopDebit 2 80 .optionalInvestment 2)).isNone &&
      (execute s (profit 2 80 1 3)).isNone),
  ("cooperative debits preserve the other balance and can never discharge the same source twice",
    (execute initial (coopDebit 1 80 .optionalInvestment 2)).any fun s =>
      s.coop == ⟨8, 9⟩ && s.projects 2 == project &&
      (execute s (coopDebit 2 80 .membership 2)).isNone),
  ("exact negative earnings are journaled without a cash transfer and block distributions in deficit",
    let loss : List Allocation := [⟨.producer, 2⟩, ⟨.pool, 3⟩]
    (execute initial (profit 1 80 0 (-5) loss)).any fun s =>
      (s.projects 2).retained == -1 && (s.projects 2).position == position &&
      s.journal 80 == some (.earnings 2 0 (-5) loss) &&
      (execute s (payout 2 81 1 [⟨.producer, 1⟩])).isNone),
  ("loss cannot be underallocated, charged twice to a holder, or charged to a nonholder",
    ([[⟨.producer, 1⟩], [⟨.pool, 1⟩, ⟨.pool, 2⟩], [⟨.investor 99, 3⟩]] : List (List Allocation)).all
      fun loss => (execute initial (profit 1 80 0 (-3) loss)).isNone),
  ("realized earnings cannot override liquidity, liabilities and reserves",
    (execute initial (profit 1 80 0 10)).any fun s =>
      (execute s (payout 2 81 1 [⟨.pool, 8⟩])).isNone &&
      (execute s (payout 2 81 1 [⟨.pool, 7⟩])).any fun next =>
        (next.projects 2).retained == 7 && (next.projects 2).position.liquid == 5 &&
        (execute next (payout 3 82 2 [⟨.pool, 1⟩] ⟨5, 3, 2⟩)).isNone),
  ("stale or mismatched position, nonholder payout and explicit policy denial are rejected",
    let r := payout 1 80 0 [⟨.pool, 1⟩]
    (execute initial (payout 1 80 0 [⟨.pool, 1⟩] position 9)).isNone &&
    (execute initial (payout 1 80 0 [⟨.pool, 1⟩] ⟨100, 0, 0⟩)).isNone &&
    (execute initial (payout 1 80 0 [⟨.investor 99, 1⟩])).isNone &&
    rejected { fixture r with allow := fun _ _ => false } initial r),
  ("allocation policy and an independent solvency gate can deny otherwise funded operations",
    let r := payout 1 80 0 [⟨.pool, 1⟩]
    let loss := profit 1 80 0 (-3) [⟨.pool, 3⟩]
    rejected { fixture r with distributionSolvent := fun _ _ _ => false } initial r &&
    rejected { fixture r with allocationAllowed := fun _ _ _ => false } initial r &&
    rejected { fixture loss with allocationAllowed := fun _ _ _ => false } initial loss)
]

end CapitalRegression

def main : IO Unit := do
  for (name, passed) in CapitalRegression.cases do
    unless passed do
      throw (IO.userError s!"FAIL {name}")
    IO.println s!"PASS {name}"
