import Replay
import Lean.Data.Json

/-!
Test-only wire oracle for differential execution. These decoders do not supply
source authentication or public request admission. The Python public boundary
independently rejects duplicate JSON keys, size/depth excess and host-field
injection before any fixture-shaped context exists. This module deliberately
allows semantically invalid values so the kernel's refusal paths are exercised.
-/
namespace PlanningWire
open Lean EconomicPlanning

abbrev Decoder (α : Type) := Json → Except String α

def exactFields (j : Json) (names : List String) : Except String Unit := do
  let fields ← j.getObj?
  let actual := fields.toList.map Prod.fst
  unless actual.length == names.length && actual.all names.contains do
    throw "unexpected object fields"

def field (j : Json) (name : String) (decode : Decoder α) : Except String α :=
  j.getObjVal? name >>= decode

def nat : Decoder Nat := fun j => do
  let value ← j.getStr?
  let some n := value.toNat? | throw "canonical decimal string expected"
  unless toString n == value && n ≤ 9223372036854775807 do
    throw "canonical bounded natural expected"
  return n

def optional (decode : Decoder α) : Decoder (Option α) := fun j =>
  if j.isNull then pure none else some <$> decode j

def list (decode : Decoder α) : Decoder (List α) := fun j => do
  (← j.getArr?).toList.mapM decode

def family : Decoder Family := fun j => do
  match ← j.getStr? with
  | "dispatch" => return .dispatch
  | "environment" => return .environment
  | "fuel" => return .fuel
  | "commodity" => return .commodity
  | "preciousMetal" => return .preciousMetal
  | "market" => return .market
  | "centralBank" => return .centralBank
  | "geopolitics" => return .geopolitics
  | _ => throw "unknown family"

def measure : Decoder Measure := fun j => do
  match ← j.getStr? with
  | "physicalQuantity" => return .physicalQuantity
  | "moneyMinorUnits" => return .moneyMinorUnits
  | "indicator" => return .indicator
  | _ => throw "unknown measure"

def instrument : Decoder Instrument := fun j => do
  match ← j.getStr? with
  | "physical" => return .physical
  | "spot" => return .spot
  | "forward" => return .forward
  | "futures" => return .futures
  | "policy" => return .policy
  | "observation" => return .observation
  | _ => throw "unknown instrument"

def origin : Decoder Origin := fun j => do
  match ← j.getStr? with
  | "observed" => return .observed
  | "synthetic" => return .synthetic
  | "hypothetical" => return .hypothetical
  | _ => throw "unknown origin"

def mode : Decoder Mode := fun j => do
  match ← j.getStr? with
  | "road" => return .road
  | "air" => return .air
  | "sea" => return .sea
  | "rail" => return .rail
  | "inlandWater" => return .inlandWater
  | "production" => return .production
  | "storage" => return .storage
  | _ => throw "unknown mode"

def claim : Decoder Claim := fun j => do
  match ← j.getStr? with
  | "observed" => return .observed
  | "nowcast" => return .nowcast
  | "forecast" => return .forecast
  | "scenario" => return .scenario
  | _ => throw "unknown claim"

def sourceRef : Decoder SourceRef := fun j => do
  exactFields j ["source", "revision"]
  return {
    source := ← field j "source" Json.getStr?, revision := ← field j "revision" Json.getStr? }

def signalKey : Decoder SignalKey := fun j => do
  exactFields j ["family", "measure", "subject", "material", "grade", "form", "unit",
    "currency", "location", "instrument", "maturity"]
  return {
    family := ← field j "family" family
    measure := ← field j "measure" measure
    subject := ← field j "subject" Json.getStr?
    material := ← field j "material" Json.getStr?
    grade := ← field j "grade" Json.getStr?
    form := ← field j "form" Json.getStr?
    unit := ← field j "unit" Json.getStr?
    currency := ← field j "currency" Json.getStr?
    location := ← field j "location" Json.getStr?
    instrument := ← field j "instrument" instrument
    maturity := ← field j "maturity" (optional nat) }

def evidence : Decoder Evidence := fun j => do
  exactFields j ["ref", "key", "scope", "publishedAt", "receivedAt", "effectiveFrom",
    "effectiveUntil", "origin", "quantity", "payloadDigest"]
  return {
    ref := ← field j "ref" sourceRef
    key := ← field j "key" signalKey
    scope := ← field j "scope" Json.getStr?
    publishedAt := ← field j "publishedAt" nat
    receivedAt := ← field j "receivedAt" nat
    effectiveFrom := ← field j "effectiveFrom" nat
    effectiveUntil := ← field j "effectiveUntil" nat
    origin := ← field j "origin" origin
    quantity := ← field j "quantity" (optional nat)
    payloadDigest := ← field j "payloadDigest" Json.getStr? }

def evidenceRequest : Decoder EvidenceRequest := fun j => do
  exactFields j ["expectedRef", "expectedKey", "evidence"]
  return {
    expectedRef := ← field j "expectedRef" sourceRef
    expectedKey := ← field j "expectedKey" signalKey
    evidence := ← field j "evidence" evidence }

def resourceKey : Decoder ResourceKey := fun j => do
  exactFields j ["scope", "constraintId", "bucket"]
  return {
    scope := ← field j "scope" Json.getStr?
    constraintId := ← field j "constraintId" Json.getStr?
    bucket := ← field j "bucket" nat }

def resource : Decoder Resource := fun j => do
  exactFields j ["source", "signal", "capacity"]
  return {
    source := ← field j "source" sourceRef
    signal := ← field j "signal" signalKey
    capacity := ← field j "capacity" (optional nat) }

def allocation : Decoder Allocation := fun j => do
  exactFields j ["resource", "source", "signal", "quantity", "mode"]
  return {
    resource := ← field j "resource" resourceKey
    source := ← field j "source" sourceRef
    signal := ← field j "signal" signalKey
    quantity := ← field j "quantity" nat
    mode := ← field j "mode" mode }

def costLine : Decoder CostLine := fun j => do
  exactFields j ["source", "signal", "atTime", "components", "currency", "minorUnits"]
  return {
    source := ← field j "source" sourceRef
    signal := ← field j "signal" signalKey
    atTime := ← field j "atTime" nat
    components := ← field j "components" (list Json.getStr?)
    currency := ← field j "currency" Json.getStr?
    minorUnits := ← field j "minorUnits" nat }

def manifest : Decoder Manifest := fun j => do
  exactFields j ["scope", "issuedAt", "horizonStart", "horizonEnd", "snapshot", "model",
    "scenario", "seed", "currency"]
  return {
    scope := ← field j "scope" Json.getStr?
    issuedAt := ← field j "issuedAt" nat
    horizonStart := ← field j "horizonStart" nat
    horizonEnd := ← field j "horizonEnd" nat
    snapshot := ← field j "snapshot" Json.getStr?
    model := ← field j "model" Json.getStr?
    scenario := ← field j "scenario" Json.getStr?
    seed := ← field j "seed" nat
    currency := ← field j "currency" Json.getStr? }

def action : Decoder Action := fun j => do
  match ← field j "kind" Json.getStr? with
  | "evidence" =>
    exactFields j ["kind", "request"]
    return .evidence (← field j "request" evidenceRequest)
  | "allocate" =>
    exactFields j ["kind", "allocation"]
    return .allocate (← field j "allocation" allocation)
  | "cost" =>
    exactFields j ["kind", "line"]
    return .cost (← field j "line" costLine)
  | "publish" =>
    exactFields j ["kind", "claim"]
    return .publish (← field j "claim" claim)
  | _ => throw "unknown action"

structure ResourceEntry where
  key : ResourceKey
  value : Resource

def resourceEntry : Decoder ResourceEntry := fun j => do
  exactFields j ["key", "value"]
  return { key := ← field j "key" resourceKey, value := ← field j "value" resource }

structure Bundle where
  manifest : Manifest
  sources : List Evidence
  readable : List SourceRef
  resources : List ResourceEntry
  operationalToken : String
  actions : List Action

def bundle : Decoder Bundle := fun j => do
  exactFields j ["manifest", "sources", "readable", "resources", "operationalToken", "actions"]
  return {
    manifest := ← field j "manifest" manifest
    sources := ← field j "sources" (list evidence)
    readable := ← field j "readable" (list sourceRef)
    resources := ← field j "resources" (list resourceEntry)
    operationalToken := ← field j "operationalToken" Json.getStr?
    actions := ← field j "actions" (list action) }

def Bundle.context (b : Bundle) : Context :=
  { manifest := b.manifest
    source := fun ref => b.sources.find? fun e => decide (e.ref = ref)
    canRead := fun ref => decide (ref ∈ b.readable)
    resource := fun key => (b.resources.find? fun r => decide (r.key = key)).map ResourceEntry.value }

def encodeNat (n : Nat) : Json := .str (toString n)
def encodeOption (encode : α → Json) : Option α → Json
  | none => .null
  | some value => encode value
def encodeList (encode : α → Json) (values : List α) : Json := .arr (values.map encode).toArray

def encodeFamily : Family → Json
  | .dispatch => .str "dispatch"
  | .environment => .str "environment"
  | .fuel => .str "fuel"
  | .commodity => .str "commodity"
  | .preciousMetal => .str "preciousMetal"
  | .market => .str "market"
  | .centralBank => .str "centralBank"
  | .geopolitics => .str "geopolitics"

def encodeMeasure : Measure → Json
  | .physicalQuantity => .str "physicalQuantity"
  | .moneyMinorUnits => .str "moneyMinorUnits"
  | .indicator => .str "indicator"

def encodeInstrument : Instrument → Json
  | .physical => .str "physical"
  | .spot => .str "spot"
  | .forward => .str "forward"
  | .futures => .str "futures"
  | .policy => .str "policy"
  | .observation => .str "observation"

def encodeOrigin : Origin → Json
  | .observed => .str "observed"
  | .synthetic => .str "synthetic"
  | .hypothetical => .str "hypothetical"

def encodeMode : Mode → Json
  | .road => .str "road"
  | .air => .str "air"
  | .sea => .str "sea"
  | .rail => .str "rail"
  | .inlandWater => .str "inlandWater"
  | .production => .str "production"
  | .storage => .str "storage"

def encodeClaim : Claim → Json
  | .observed => .str "observed"
  | .nowcast => .str "nowcast"
  | .forecast => .str "forecast"
  | .scenario => .str "scenario"

def encodeSourceRef (r : SourceRef) : Json := Json.mkObj [
  ("source", .str r.source), ("revision", .str r.revision)]

def encodeSignalKey (k : SignalKey) : Json := Json.mkObj [
  ("family", encodeFamily k.family), ("measure", encodeMeasure k.measure),
  ("subject", .str k.subject), ("material", .str k.material), ("grade", .str k.grade),
  ("form", .str k.form), ("unit", .str k.unit), ("currency", .str k.currency),
  ("location", .str k.location), ("instrument", encodeInstrument k.instrument),
  ("maturity", encodeOption encodeNat k.maturity)]

def encodeEvidence (e : Evidence) : Json := Json.mkObj [
  ("ref", encodeSourceRef e.ref), ("key", encodeSignalKey e.key), ("scope", .str e.scope),
  ("publishedAt", encodeNat e.publishedAt), ("receivedAt", encodeNat e.receivedAt),
  ("effectiveFrom", encodeNat e.effectiveFrom), ("effectiveUntil", encodeNat e.effectiveUntil),
  ("origin", encodeOrigin e.origin), ("quantity", encodeOption encodeNat e.quantity),
  ("payloadDigest", .str e.payloadDigest)]

def encodeResourceKey (k : ResourceKey) : Json := Json.mkObj [
  ("scope", .str k.scope), ("constraintId", .str k.constraintId), ("bucket", encodeNat k.bucket)]

def encodeAllocation (a : Allocation) : Json := Json.mkObj [
  ("resource", encodeResourceKey a.resource), ("source", encodeSourceRef a.source),
  ("signal", encodeSignalKey a.signal), ("quantity", encodeNat a.quantity),
  ("mode", encodeMode a.mode)]

def encodeCostLine (c : CostLine) : Json := Json.mkObj [
  ("source", encodeSourceRef c.source), ("signal", encodeSignalKey c.signal),
  ("atTime", encodeNat c.atTime), ("components", encodeList Json.str c.components),
  ("currency", .str c.currency), ("minorUnits", encodeNat c.minorUnits)]

def encodeManifest (m : Manifest) : Json := Json.mkObj [
  ("scope", .str m.scope), ("issuedAt", encodeNat m.issuedAt),
  ("horizonStart", encodeNat m.horizonStart), ("horizonEnd", encodeNat m.horizonEnd),
  ("snapshot", .str m.snapshot), ("model", .str m.model), ("scenario", .str m.scenario),
  ("seed", encodeNat m.seed), ("currency", .str m.currency)]

def encodeCertificate (c : Certificate) : Json := Json.mkObj [
  ("manifest", encodeManifest c.manifest), ("claim", encodeClaim c.claim),
  ("evidence", encodeList encodeEvidence c.evidence),
  ("allocations", encodeList encodeAllocation c.allocations), ("costs", encodeList encodeCostLine c.costs)]

def encodeState (s : State) : Json := Json.mkObj [
  ("evidence", encodeList encodeEvidence s.evidence),
  ("allocations", encodeList encodeAllocation s.allocations),
  ("costs", encodeList encodeCostLine s.costs),
  ("publications", encodeList encodeCertificate s.publications),
  ("operationalToken", .str s.operationalToken)]

/-- Diagnostic states are test evidence, never a public partially accepted plan. -/
structure Report where
  states : List State
  rejectedAt : Option Nat

def reportFrom (ctx : Context) : State → List Action → Report
  | s, [] => ⟨[s], none⟩
  | s, a :: rest => match step ctx s a with
    | none => ⟨[s], some 0⟩
    | some next =>
      let tail := reportFrom ctx next rest
      ⟨s :: tail.states, tail.rejectedAt.map (· + 1)⟩

def run (b : Bundle) : Except String Json := do
  let report := reportFrom b.context (initial b.operationalToken) b.actions
  let accepted := replay b.context b.operationalToken b.actions
  -- Compare the diagnostic execution with the exact proved all-or-nothing
  -- replay. A diagnostic bug must fail the oracle instead of inventing output.
  unless accepted.isSome == report.rejectedAt.isNone do
    throw "oracle/replay acceptance mismatch"
  match accepted with
  | none => pure ()
  | some s =>
    unless report.states.getLast? == some s do
      throw "oracle/replay final state mismatch"
  return Json.mkObj [
    ("accepted", .bool accepted.isSome),
    ("rejectedAt", encodeOption encodeNat report.rejectedAt),
    ("states", encodeList encodeState report.states)]

end PlanningWire
