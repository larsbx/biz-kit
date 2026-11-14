import Std

/-!
An inert planning verification kernel. All clocks, source authentication, canonical
identities, source completeness and catalog construction are supplied by the host.
No operation here authenticates a provider or changes a business resource.
-/
namespace EconomicPlanning

inductive Family where
  | dispatch | environment | fuel | commodity | preciousMetal | market | centralBank | geopolitics
  deriving DecidableEq, Repr

inductive Instrument where
  | physical | spot | forward | futures | policy | observation
  deriving DecidableEq, Repr

inductive Origin where
  | observed | synthetic | hypothetical
  deriving DecidableEq, Repr

inductive Measure where
  | physicalQuantity | moneyMinorUnits | indicator
  deriving DecidableEq, Repr

inductive Mode where
  | road | air | sea | rail | inlandWater | production | storage
  deriving DecidableEq, Repr

inductive Claim where
  | observed | nowcast | forecast | scenario
  deriving DecidableEq, Repr

structure SourceRef where
  source : String
  revision : String
  deriving DecidableEq, Repr

/-- Values can be compared only after all these identities match. -/
structure SignalKey where
  family : Family
  measure : Measure
  subject : String
  material : String
  grade : String
  form : String
  unit : String
  currency : String
  location : String
  instrument : Instrument
  maturity : Option Nat
  deriving DecidableEq, Repr

structure Evidence where
  ref : SourceRef
  key : SignalKey
  scope : String
  publishedAt : Nat
  receivedAt : Nat
  effectiveFrom : Nat
  effectiveUntil : Nat
  origin : Origin
  quantity : Option Nat
  payloadDigest : String
  deriving DecidableEq, Repr

structure EvidenceRequest where
  expectedRef : SourceRef
  expectedKey : SignalKey
  evidence : Evidence
  deriving DecidableEq, Repr

/-- One canonical physical constraint and one host-normalized time bucket.
Units, material and transport mode do not create additional resource pools. -/
structure ResourceKey where
  scope : String
  constraintId : String
  bucket : Nat
  deriving DecidableEq, Repr

structure Resource where
  source : SourceRef
  signal : SignalKey
  capacity : Option Nat
  deriving DecidableEq, Repr

structure Allocation where
  resource : ResourceKey
  source : SourceRef
  signal : SignalKey
  quantity : Nat
  mode : Mode
  deriving DecidableEq, Repr

/-- Component IDs denote canonical atomic economic effects, not news reports or
common shocks. Different effects of one shock have different component IDs. -/
structure CostLine where
  source : SourceRef
  signal : SignalKey
  atTime : Nat
  components : List String
  currency : String
  minorUnits : Nat
  deriving DecidableEq, Repr

structure Manifest where
  scope : String
  issuedAt : Nat
  horizonStart : Nat
  horizonEnd : Nat
  snapshot : String
  model : String
  scenario : String
  seed : Nat
  currency : String
  deriving DecidableEq, Repr

structure Context where
  manifest : Manifest
  source : SourceRef → Option Evidence
  canRead : SourceRef → Bool
  resource : ResourceKey → Option Resource

structure Certificate where
  manifest : Manifest
  claim : Claim
  evidence : List Evidence
  allocations : List Allocation
  costs : List CostLine
  deriving DecidableEq, Repr

structure State where
  evidence : List Evidence := []
  allocations : List Allocation := []
  costs : List CostLine := []
  publications : List Certificate := []
  operationalToken : String
  deriving DecidableEq, Repr

def initial (operationalToken : String) : State := { operationalToken }

def used : List Allocation → ResourceKey → Nat
  | [], _ => 0
  | a :: rest, key => (if a.resource = key then a.quantity else 0) + used rest key

def covered (costs : List CostLine) : List String := costs.flatMap CostLine.components

def EvidenceConditions (ctx : Context) (s : State) (r : EvidenceRequest) : Prop :=
  r.expectedRef = r.evidence.ref ∧ r.expectedKey = r.evidence.key ∧
  ctx.source r.expectedRef = some r.evidence ∧
  ctx.canRead r.expectedRef = true ∧ r.evidence.scope = ctx.manifest.scope ∧
  r.evidence.publishedAt ≤ ctx.manifest.issuedAt ∧
  r.evidence.receivedAt ≤ ctx.manifest.issuedAt ∧
  r.evidence.effectiveFrom < r.evidence.effectiveUntil ∧
  r.evidence.payloadDigest ≠ "" ∧ r.evidence.ref ∉ s.evidence.map Evidence.ref

instance (ctx : Context) (s : State) (r : EvidenceRequest) :
    Decidable (EvidenceConditions ctx s r) := inferInstanceAs (Decidable (_ ∧ _))

def admitEvidence (ctx : Context) (s : State) (r : EvidenceRequest) : Option State :=
  if EvidenceConditions ctx s r then some { s with evidence := s.evidence ++ [r.evidence] }
  else none

/-- A capacity number must match an actual admitted quantity, source and complete
signal key. The frozen host catalog additionally binds its resource identity. -/
def linked (s : State) (r : Resource) (atTime : Nat) : Bool := s.evidence.any fun e =>
  decide (e.ref = r.source ∧ e.key = r.signal ∧ e.quantity = r.capacity ∧
    e.effectiveFrom ≤ atTime ∧ atTime < e.effectiveUntil ∧ e.key.measure = .physicalQuantity)

def AllocationConditions (ctx : Context) (s : State) (a : Allocation)
    (r : Resource) (capacity : Nat) : Prop :=
  a.resource.scope = ctx.manifest.scope ∧ a.source = r.source ∧ a.signal = r.signal ∧
  linked s r a.resource.bucket = true ∧
  ctx.manifest.horizonStart ≤ a.resource.bucket ∧ a.resource.bucket < ctx.manifest.horizonEnd ∧
  0 < a.quantity ∧ used s.allocations a.resource + a.quantity ≤ capacity

instance (ctx : Context) (s : State) (a : Allocation) (r : Resource) (cap : Nat) :
    Decidable (AllocationConditions ctx s a r cap) := inferInstanceAs (Decidable (_ ∧ _))

def allocate (ctx : Context) (s : State) (a : Allocation) : Option State :=
  match ctx.resource a.resource with
  | none => none
  | some r => match r.capacity with
    | none => none
    | some capacity =>
      if AllocationConditions ctx s a r capacity then
        some { s with allocations := s.allocations ++ [a] }
      else none

def costLinked (s : State) (line : CostLine) : Bool := s.evidence.any fun e =>
  decide (e.ref = line.source ∧ e.key = line.signal ∧ e.quantity = some line.minorUnits ∧
    e.key.currency = line.currency ∧ e.effectiveFrom ≤ line.atTime ∧ line.atTime < e.effectiveUntil ∧
    e.key.measure = .moneyMinorUnits ∧ e.key.unit = "minor-unit")

def CostConditions (ctx : Context) (s : State) (line : CostLine) : Prop :=
  line.currency = ctx.manifest.currency ∧ line.components ≠ [] ∧ line.components.Nodup ∧
  (∀ component ∈ line.components, component ∉ covered s.costs) ∧
  costLinked s line = true ∧ ctx.manifest.horizonStart ≤ line.atTime ∧ line.atTime < ctx.manifest.horizonEnd ∧
  line.source ∉ s.costs.map CostLine.source

instance (ctx : Context) (s : State) (line : CostLine) :
    Decidable (CostConditions ctx s line) := inferInstanceAs (Decidable (_ ∧ _))

def addCost (ctx : Context) (s : State) (line : CostLine) : Option State :=
  if CostConditions ctx s line then some { s with costs := s.costs ++ [line] } else none

def allObserved (s : State) : Bool := s.evidence.all fun e => decide (e.origin = .observed)

def ClaimHorizon (m : Manifest) : Claim → Prop
  | .observed => False
  | .nowcast => m.horizonStart ≤ m.issuedAt ∧ m.issuedAt < m.horizonEnd
  | .forecast => m.issuedAt < m.horizonStart
  | .scenario => True

instance (m : Manifest) (claim : Claim) : Decidable (ClaimHorizon m claim) := by
  cases claim <;> unfold ClaimHorizon <;> infer_instance

def PublicationConditions (ctx : Context) (s : State) (claim : Claim) : Prop :=
  s.evidence ≠ [] ∧ claim ≠ .observed ∧ (allObserved s = true ∨ claim = .scenario) ∧
  ctx.manifest.horizonStart < ctx.manifest.horizonEnd ∧ ctx.manifest.scope ≠ "" ∧
  ctx.manifest.snapshot ≠ "" ∧ ctx.manifest.model ≠ "" ∧
  ctx.manifest.scenario ≠ "" ∧ ctx.manifest.currency ≠ "" ∧ ClaimHorizon ctx.manifest claim

instance (ctx : Context) (s : State) (claim : Claim) : Decidable (PublicationConditions ctx s claim) :=
  inferInstanceAs (Decidable (_ ∧ _))

def certificate (ctx : Context) (s : State) (claim : Claim) : Certificate :=
  { manifest := ctx.manifest, claim, evidence := s.evidence,
    allocations := s.allocations, costs := s.costs }

def publish (ctx : Context) (s : State) (claim : Claim) : Option State :=
  if PublicationConditions ctx s claim then
    some { s with publications := s.publications ++ [certificate ctx s claim] }
  else none

inductive Action where
  | evidence (request : EvidenceRequest)
  | allocate (allocation : Allocation)
  | cost (line : CostLine)
  | publish (claim : Claim)
  deriving DecidableEq, Repr

def step (ctx : Context) (s : State) : Action → Option State
  | .evidence r => admitEvidence ctx s r
  | .allocate a => allocate ctx s a
  | .cost line => addCost ctx s line
  | .publish claim => publish ctx s claim

inductive Trace (ctx : Context) : State → State → Prop where
  | refl (s) : Trace ctx s s
  | next {first middle last} (prior : Trace ctx first middle)
      (action : Action) (accepted : step ctx middle action = some last) : Trace ctx first last

def CapacitySafe (ctx : Context) (s : State) : Prop := ∀ key,
  match ctx.resource key with
  | none => used s.allocations key = 0
  | some r => match r.capacity with
    | none => used s.allocations key = 0
    | some capacity => used s.allocations key ≤ capacity

def SourcesSafe (ctx : Context) (s : State) : Prop := ∀ e ∈ s.evidence,
  ctx.source e.ref = some e ∧ ctx.canRead e.ref = true ∧ e.scope = ctx.manifest.scope ∧
  e.publishedAt ≤ ctx.manifest.issuedAt ∧ e.receivedAt ≤ ctx.manifest.issuedAt

def CostsSafe (ctx : Context) (s : State) : Prop :=
  (covered s.costs).Nodup ∧ ∀ line ∈ s.costs, line.currency = ctx.manifest.currency

end EconomicPlanning
