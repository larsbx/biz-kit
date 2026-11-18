import Std

namespace ProducerCapital

inductive Owner where
  | producer
  | pool
  | investor (business : Nat)
  deriving DecidableEq, Repr

inductive CoopClass where
  | membership
  | optionalInvestment
  deriving DecidableEq, Repr

inductive Consideration where
  | cash
  | barter
  deriving DecidableEq, Repr

structure Position where
  liquid : Nat
  liabilities : Nat
  reserves : Nat
  deriving DecidableEq, Repr

structure Allocation where
  owner : Owner
  amount : Nat
  deriving DecidableEq, Repr

structure Project where
  issued : Nat
  owners : List Owner
  version : Nat
  currency : Nat
  retained : Int
  position : Position
  deriving DecidableEq, Repr

structure CoopAccounts where
  membership : Nat
  optionalInvestment : Nat
  deriving DecidableEq, Repr

structure Purchase where
  project : Nat
  version : Nat
  seller : Owner
  serials : List Nat
  currency : Nat
  amount : Nat
  kind : Consideration
  deriving DecidableEq, Repr

structure Valuation where
  project : Nat
  version : Nat
  currency : Nat
  perUnit : Nat
  asOf : Nat
  expires : Nat
  grant : Nat
  deriving DecidableEq, Repr

inductive Effect where
  | sale (terms : Purchase)
  | earnings (project version : Nat) (net : Int) (loss : List Allocation)
  | distribution (project version : Nat) (position : Position) (asOf : Nat)
      (allocations : List Allocation)
  | coopDischarge (account : CoopClass) (amount : Nat)
  deriving DecidableEq, Repr

structure State where
  projects : Nat → Project
  coop : CoopAccounts
  usedTx : Nat → Bool := fun _ => false
  journal : Nat → Option Effect := fun _ => none
  revoked : Nat → Bool := fun _ => false
  now : Nat := 0

inductive Role where
  | projectAuthority (project : Nat)
  | holder (project : Nat) (owner : Owner)
  | appraiser (project : Nat)
  | projectObserver (project : Nat)
  | coopAuthority (account : CoopClass)
  | coopObserver (account : CoopClass)
  | revoker
  deriving DecidableEq, Repr

structure Grant where
  role : Role
  principal : Nat
  deriving DecidableEq, Repr

structure Observation where
  grant : Nat
  effect : Effect
  deriving DecidableEq, Repr

inductive Action where
  | purchase (source quote authority buyer seller : Nat) (terms : Purchase)
  | earnings (source authority project version : Nat) (net : Int) (loss : List Allocation)
  | distribute (source authority project version : Nat) (position : Position)
      (asOf : Nat) (allocations : List Allocation)
  | coopDischarge (source authority : Nat) (account : CoopClass) (amount : Nat)
  | revoke (authority target : Nat)
  deriving DecidableEq, Repr

structure Request where
  tx : Nat
  action : Action
  deriving DecidableEq, Repr

-- Read-only evidence and policy interfaces supplied by the abstract trusted boundary.
structure Context where
  now : Nat
  grant : Nat → Option Grant
  signed : Nat → Request → Bool
  valuation : Nat → Option Valuation
  observation : Nat → Option Observation
  allow : State → Request → Bool
  allocationAllowed : Nat → Project → Effect → Bool
  distributionSolvent : Nat → Project → Nat → Bool

def active (ctx : Context) (s : State) (id : Nat) (role : Role) : Bool :=
  !s.revoked id && (ctx.grant id).any (fun grant => decide (grant.role = role))

def signedBy (ctx : Context) (s : State) (r : Request) (id : Nat) (role : Role) : Bool :=
  active ctx s id role && ctx.signed id r

def independent (ctx : Context) (left right : Nat) : Bool :=
  match ctx.grant left, ctx.grant right with
  | some a, some b => decide (a.principal ≠ b.principal)
  | _, _ => false

def observed (ctx : Context) (s : State) (source : Nat) (effect : Effect)
    (role : Role) (separateFrom : List Nat) : Bool :=
  decide (s.journal source = none) && (ctx.observation source).any (fun receipt =>
    decide (receipt.effect = effect) && active ctx s receipt.grant role &&
      separateFrom.all (independent ctx receipt.grant))

def appraisalOK (ctx : Context) (s : State) (terms : Purchase)
    (quote : Nat) (separateFrom : List Nat) : Bool :=
  (ctx.valuation quote).any (fun v =>
    active ctx s v.grant (.appraiser terms.project) &&
      separateFrom.all (independent ctx v.grant) &&
      decide (v.project = terms.project ∧ v.version = terms.version ∧
        v.currency = terms.currency ∧ 0 < v.perUnit ∧
        v.asOf ≤ ctx.now ∧ ctx.now ≤ v.expires ∧
        terms.amount = terms.serials.length * v.perUnit))

def assetsAtLeast (p : Position) (amount : Nat) : Prop :=
  amount + p.liabilities + p.reserves ≤ p.liquid

instance (p : Position) (amount : Nat) : Decidable (assetsAtLeast p amount) :=
  inferInstanceAs (Decidable (_ ≤ _))

def total (allocations : List Allocation) : Nat :=
  (allocations.map Allocation.amount).sum

def holdersOnly (p : Project) (allocations : List Allocation) : Prop :=
  (allocations.map Allocation.owner).Nodup ∧
    allocations.all (fun a => decide (a.owner ∈ p.owners ∧ 0 < a.amount)) = true

instance (p : Project) (allocations : List Allocation) : Decidable (holdersOnly p allocations) :=
  inferInstanceAs (Decidable (_ ∧ _))

def validSale (p : Project) (terms : Purchase) : Prop :=
  terms.version = p.version ∧ terms.currency = p.currency ∧
    terms.seller ≠ .producer ∧ terms.serials ≠ [] ∧ terms.serials.Nodup ∧
    terms.serials.all (fun i => decide (p.owners[i]? = some terms.seller)) = true

instance (p : Project) (terms : Purchase) : Decidable (validSale p terms) :=
  inferInstanceAs (Decidable (_ ∧ _))

def buyOK (ctx : Context) (s : State) (r : Request)
    (source quote authority buyer seller : Nat) (terms : Purchase) : Bool :=
  decide (validSale (s.projects terms.project) terms) &&
    signedBy ctx s r authority (.projectAuthority terms.project) &&
    signedBy ctx s r buyer (.holder terms.project .producer) &&
    signedBy ctx s r seller (.holder terms.project terms.seller) &&
    independent ctx buyer seller &&
    appraisalOK ctx s terms quote [authority, buyer, seller] &&
    observed ctx s source (.sale terms) (.projectObserver terms.project)
      ([authority, buyer, seller] ++ ((ctx.valuation quote).map Valuation.grant).toList)

def earningsConditions (p : Project) (version : Nat) (net : Int)
    (loss : List Allocation) : Prop :=
  0 < p.issued ∧ version = p.version ∧
    ((0 < net ∧ loss = []) ∨
      (net < 0 ∧ holdersOnly p loss ∧ total loss = net.natAbs))

instance (p : Project) (version : Nat) (net : Int) (loss : List Allocation) :
    Decidable (earningsConditions p version net loss) :=
  inferInstanceAs (Decidable (_ ∧ _))

def distributionConditions (p : Project) (version now : Nat) (position : Position)
    (asOf : Nat) (allocations : List Allocation) : Prop :=
  0 < p.issued ∧ version = p.version ∧ asOf = now ∧ position = p.position ∧
    holdersOnly p allocations ∧ 0 < total allocations ∧
    (total allocations : Int) ≤ p.retained ∧ assetsAtLeast position (total allocations)

instance (p : Project) (version now : Nat) (position : Position) (asOf : Nat)
    (allocations : List Allocation) :
    Decidable (distributionConditions p version now position asOf allocations) :=
  inferInstanceAs (Decidable (_ ∧ _))

def CoopAccounts.balance (accounts : CoopAccounts) : CoopClass → Nat
  | .membership => accounts.membership
  | .optionalInvestment => accounts.optionalInvestment

def CoopAccounts.debit (accounts : CoopAccounts) (amount : Nat) : CoopClass → CoopAccounts
  | .membership => { accounts with membership := accounts.membership - amount }
  | .optionalInvestment => { accounts with optionalInvestment := accounts.optionalInvestment - amount }

def authorized (ctx : Context) (s : State) (r : Request) : Bool :=
  match r.action with
  | .purchase source quote authority buyer seller terms =>
    buyOK ctx s r source quote authority buyer seller terms
  | .earnings source authority project version net loss =>
    let p := s.projects project
    let effect := Effect.earnings project version net loss
    decide (earningsConditions p version net loss) &&
      signedBy ctx s r authority (.projectAuthority project) &&
      observed ctx s source effect (.projectObserver project) [authority] &&
      (decide (0 < net) || ctx.allocationAllowed project p effect)
  | .distribute source authority project version position asOf allocations =>
    let p := s.projects project
    let effect := Effect.distribution project version position asOf allocations
    decide (distributionConditions p version ctx.now position asOf allocations) &&
      signedBy ctx s r authority (.projectAuthority project) &&
      observed ctx s source effect (.projectObserver project) [authority] &&
      ctx.allocationAllowed project p effect && ctx.distributionSolvent project p ctx.now
  | .coopDischarge source authority account amount =>
    decide (0 < amount ∧ amount ≤ s.coop.balance account) &&
      signedBy ctx s r authority (.coopAuthority account) &&
      observed ctx s source (.coopDischarge account amount) (.coopObserver account) [authority]
  | .revoke authority target =>
    signedBy ctx s r authority .revoker && !s.revoked target

def admitted (ctx : Context) (s : State) (r : Request) : Bool :=
  !s.usedTx r.tx && decide (s.now ≤ ctx.now) && ctx.allow s r && authorized ctx s r

def Action.effect : Action → Option (Nat × Effect)
  | .purchase source _ _ _ _ terms => some (source, .sale terms)
  | .earnings source _ id version net loss => some (source, .earnings id version net loss)
  | .distribute source _ id version position asOf allocations =>
    some (source, .distribution id version position asOf allocations)
  | .coopDischarge source _ account amount => some (source, .coopDischarge account amount)
  | .revoke .. => none

def update {α : Type} (f : Nat → α) (key : Nat) (value : α) : Nat → α :=
  fun i => if i = key then value else f i

def moved (owners : List Owner) (serials : List Nat) : List Owner :=
  owners.mapIdx (fun i owner => if i ∈ serials then .producer else owner)

def changeProject (s : State) (id : Nat) (f : Project → Project) : State :=
  { s with projects := update s.projects id (f (s.projects id)) }

def applyAction (s : State) : Action → State
  | .purchase _ _ _ _ _ terms =>
    changeProject s terms.project (fun p =>
      { p with owners := moved p.owners terms.serials, version := p.version + 1 })
  | .earnings _ _ id _ net _ =>
    changeProject s id (fun p => { p with retained := p.retained + net, version := p.version + 1 })
  | .distribute _ _ id _ _ _ allocations =>
    changeProject s id (fun p =>
      { p with
        retained := p.retained - (total allocations : Int)
        position := { p.position with liquid := p.position.liquid - total allocations }
        version := p.version + 1 })
  | .coopDischarge _ _ account amount => { s with coop := s.coop.debit amount account }
  | .revoke _ target => { s with revoked := update s.revoked target true }

def commit (ctx : Context) (s : State) (r : Request) : State :=
  { applyAction s r.action with
    usedTx := update s.usedTx r.tx true
    journal := match r.action.effect with
      | some (source, effect) => update s.journal source (some effect)
      | none => s.journal
    now := ctx.now }

def step (ctx : Context) (s : State) (r : Request) : Option State :=
  if admitted ctx s r then some (commit ctx s r) else none

end ProducerCapital
