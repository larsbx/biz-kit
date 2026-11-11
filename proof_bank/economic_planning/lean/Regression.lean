import Proofs

open EconomicPlanning

namespace PlanningFixtures

def materialKey : SignalKey :=
  { family := .commodity, measure := .physicalQuantity, subject := "handling-capacity", material := "copper",
    grade := "grade-a", form := "cathode", unit := "metric-tonne", currency := "",
    location := "port-alpha", instrument := .physical, maturity := none }

def priceKey : SignalKey :=
  { materialKey with
    subject := "delivered-quote", measure := .moneyMinorUnits, unit := "minor-unit", currency := "USD",
    instrument := .spot }

def evidence (name : String) (quantity : Option Nat) (key : SignalKey := materialKey)
    (origin : Origin := .observed) (start : Nat := 0) (finish : Nat := 100) : Evidence :=
  { ref := ⟨name, "revision-1"⟩, key, scope := "business-north", publishedAt := 5,
    receivedAt := 8, effectiveFrom := start, effectiveUntil := finish, origin, quantity,
    payloadDigest := "synthetic-fixture-digest" }

def cap := evidence "capacity" (some 2)
def unknown := evidence "unknown-capacity" none
def zero := evidence "zero-capacity" (some 0)
def future := evidence "future-capacity" (some 2) materialKey .observed 30 40
def quote := evidence "quote" (some 100) priceKey
def fee := evidence "storage-quote" (some 20) priceKey
def repeatedReport := evidence "second-report" (some 20) priceKey
def synthetic := evidence "synthetic-capacity" (some 3) materialKey .synthetic
def hypothetical := evidence "hypothetical-cost" (some 30) priceKey .hypothetical
def physicalWithCurrency := evidence "physical-with-currency" (some 2)
  { materialKey with unit := "fine-troy-ounce", currency := "USD" }
def denied := evidence "denied" (some 2)
def lateReceipt := { cap with ref := ⟨"late-receipt", "revision-1"⟩, receivedAt := 11 }
def latePublication := { cap with ref := ⟨"late-publication", "revision-1"⟩, publishedAt := 11 }
def observedInputs := [cap, unknown, zero, future, quote, fee, repeatedReport]
def sources := observedInputs ++ [synthetic, hypothetical, physicalWithCurrency, denied, lateReceipt, latePublication]

def manifest : Manifest :=
  { scope := "business-north", issuedAt := 10, horizonStart := 10, horizonEnd := 60,
    snapshot := "snapshot-1", model := "model-1", scenario := "baseline", seed := 19,
    currency := "USD" }

def resourceFor (key : ResourceKey) : Option Resource := do
  if key.scope ≠ "business-north" then none else do
    let e ← match key.constraintId with
      | "shared" => some cap
      | "unknown" => some unknown
      | "zero" => some zero
      | "future" => some future
      | _ => none
    pure { source := e.ref, signal := e.key, capacity := e.quantity }

def ctx : Context :=
  { manifest, source := fun ref => sources.find? (fun e => decide (e.ref = ref)),
    canRead := fun ref => decide (ref.source ≠ "denied"), resource := resourceFor }

def forwardCtx : Context := { ctx with manifest := { manifest with horizonStart := 20 } }

def request (e : Evidence) : EvidenceRequest := ⟨e.ref, e.key, e⟩

def admitAll (context : Context) : State → List Evidence → Option State
  | s, [] => some s
  | s, e :: es => (admitEvidence context s (request e)).bind fun next => admitAll context next es

def opening := initial "existing-operations-revision-7"
def readyResult := admitAll ctx opening observedInputs
def ready := readyResult.getD opening

def allocation (id : String) (bucket : Nat := 20) (amount : Nat := 1)
    (mode : Mode := .sea) : Allocation :=
  let key : ResourceKey := ⟨"business-north", id, bucket⟩
  let r := (resourceFor key).getD ⟨cap.ref, cap.key, none⟩
  ⟨key, r.source, r.signal, amount, mode⟩

def sea := allocation "shared"
def air := allocation "shared" 20 1 .air
def road := allocation "shared" 20 1 .road
def seaResult := allocate ctx ready sea
def seaState := seaResult.getD opening
def fullResult := allocate ctx seaState air
def fullState := fullResult.getD opening

def allIn : CostLine :=
  { source := quote.ref, signal := priceKey, atTime := 20, minorUnits := 100,
    currency := "USD", components := ["shock-1:shipment-a:freight", "shock-1:shipment-a:fuel",
      "shock-1:shipment-a:insurance"] }
def storage : CostLine :=
  { source := fee.ref, signal := priceKey, atTime := 20, minorUnits := 20,
    currency := "USD", components := ["shock-1:shipment-a:storage"] }
def duplicateReport : CostLine :=
  { storage with source := repeatedReport.ref, components := ["shock-1:shipment-a:fuel"] }
def costResult := addCost ctx fullState allIn
def costState := costResult.getD opening
def bothCostResult := addCost ctx costState storage
def bothCostState := bothCostResult.getD opening
def publishedResult := publish ctx bothCostState .nowcast
def published := publishedResult.getD opening
def syntheticResult := admitEvidence ctx published (request synthetic)
def syntheticState := syntheticResult.getD opening
def hypotheticalResult := admitEvidence ctx ready (request hypothetical)
def hypotheticalState := hypotheticalResult.getD opening
def hypotheticalLine := { storage with source := hypothetical.ref, minorUnits := 30 }
def physicalCurrencyState := (admitEvidence ctx ready (request physicalWithCurrency)).getD opening

def checks : List (String × Bool) := [
  ("observed_inputs_admitted", readyResult.isSome && decide (ready.evidence.length = 7)),
  ("known_future_announcement_admitted", decide (future ∈ ready.evidence)),
  ("unknown_and_zero_remain_distinct", decide (unknown.quantity ≠ zero.quantity)),
  ("sea_allocation_positive", seaResult.isSome && decide (used seaState.allocations sea.resource = 1)),
  ("air_shares_sea_capacity", fullResult.isSome && decide (used fullState.allocations sea.resource = 2)),
  ("cross_mode_overbooking_refused", (allocate ctx fullState road).isNone),
  ("separate_bucket_capacity", (allocate ctx fullState (allocation "shared" 21)).isSome),
  ("unknown_capacity_refused", (allocate ctx ready (allocation "unknown")).isNone),
  ("zero_capacity_refused", (allocate ctx ready (allocation "zero")).isNone),
  ("zero_allocation_refused", (allocate ctx ready (allocation "shared" 20 0)).isNone),
  ("future_capacity_not_applied_early", (allocate ctx ready (allocation "future" 20)).isNone),
  ("future_capacity_at_effective_time", (allocate ctx ready (allocation "future" 30)).isSome),
  ("expired_capacity_refused", (allocate ctx ready (allocation "future" 40)).isNone),
  ("outside_horizon_refused", (allocate ctx ready (allocation "shared" 60)).isNone),
  ("unadmitted_capacity_refused", (allocate ctx opening sea).isNone),
  ("capacity_catalog_value_mismatch_refused", (allocate
    { ctx with resource := fun k => (resourceFor k).map fun r => { r with capacity := some 9 } }
    ready sea).isNone),
  ("wrong_resource_scope_refused", (allocate ctx ready { sea with resource :=
    { sea.resource with scope := "business-south" } }).isNone),
  ("wrong_material_refused", (allocate ctx ready { sea with signal :=
    { sea.signal with material := "silver" } }).isNone),
  ("wrong_unit_refused", (allocate ctx ready { sea with signal :=
    { sea.signal with unit := "troy-ounce" } }).isNone),
  ("wrong_grade_refused", (allocate ctx ready { sea with signal :=
    { sea.signal with grade := "different-grade" } }).isNone),
  ("wrong_instrument_refused", (allocate ctx ready { sea with signal :=
    { sea.signal with instrument := .futures } }).isNone),
  ("wrong_maturity_refused", (allocate ctx ready { sea with signal :=
    { sea.signal with maturity := some 99 } }).isNone),
  ("wrong_source_revision_refused", (allocate ctx ready { sea with source :=
    { sea.source with revision := "revision-2" } }).isNone),
  ("future_receipt_refused", (admitEvidence ctx opening (request lateReceipt)).isNone),
  ("future_publication_refused", (admitEvidence ctx opening (request latePublication)).isNone),
  ("denied_read_refused", (admitEvidence ctx opening (request denied)).isNone),
  ("source_payload_substitution_refused", (admitEvidence ctx opening
    (request { cap with quantity := some 9 })).isNone),
  ("expected_key_substitution_refused", (admitEvidence ctx opening
    { request cap with expectedKey := { cap.key with material := "silver" } }).isNone),
  ("expected_revision_substitution_refused", (admitEvidence ctx opening
    { request cap with expectedRef := { cap.ref with revision := "revision-2" } }).isNone),
  ("duplicate_evidence_refused", (admitEvidence ctx ready (request cap)).isNone),
  ("all_in_cost_admitted", costResult.isSome),
  ("different_effect_same_shock_admitted", bothCostResult.isSome &&
    decide ((covered bothCostState.costs).length = 4)),
  ("same_effect_different_report_refused", (addCost ctx costState duplicateReport).isNone),
  ("duplicate_quote_renamed_components_refused", (addCost ctx costState
    { allIn with components := ["different-component-name"] }).isNone),
  ("duplicate_components_in_line_refused", (addCost ctx ready
    { allIn with components := ["fuel", "fuel"] }).isNone),
  ("empty_components_refused", (addCost ctx ready { allIn with components := [] }).isNone),
  ("wrong_cost_currency_refused", (addCost ctx ready { allIn with currency := "EUR" }).isNone),
  ("invented_cost_amount_refused", (addCost ctx ready { allIn with minorUnits := 101 }).isNone),
  ("physical_quantity_as_money_refused", (addCost ctx physicalCurrencyState
    { allIn with
      source := physicalWithCurrency.ref, signal := physicalWithCurrency.key,
      minorUnits := 2 }).isNone),
  ("money_as_physical_capacity_refused", (allocate
    { ctx with resource := fun _ => some ⟨quote.ref, quote.key, quote.quantity⟩ }
    ready { sea with source := quote.ref, signal := quote.key }).isNone),
  ("unadmitted_cost_source_refused", (addCost ctx opening allIn).isNone),
  ("cost_outside_horizon_refused", (addCost ctx ready { allIn with atTime := 60 }).isNone),
  ("nowcast_publication_positive", publishedResult.isSome && decide (published.publications.length = 1)),
  ("forecast_publication_positive", (publish forwardCtx bothCostState .forecast).isSome),
  ("forecast_current_horizon_refused", (publish ctx bothCostState .forecast).isNone),
  ("nowcast_future_horizon_refused", (publish forwardCtx bothCostState .nowcast).isNone),
  ("derived_observation_refused", (publish ctx ready .observed).isNone),
  ("empty_evidence_publication_refused", (publish ctx opening .scenario).isNone),
  ("empty_horizon_refused", (publish { ctx with manifest :=
    { manifest with horizonEnd := manifest.horizonStart } } ready .scenario).isNone),
  ("missing_snapshot_pin_refused", (publish { ctx with manifest :=
    { manifest with snapshot := "" } } ready .scenario).isNone),
  ("synthetic_dependency_cannot_be_nowcast", syntheticResult.isSome &&
    (publish ctx syntheticState .nowcast).isNone),
  ("synthetic_scenario_positive", (publish ctx syntheticState .scenario).isSome),
  ("hypothetical_cost_source_admitted", hypotheticalResult.isSome &&
    (addCost ctx hypotheticalState hypotheticalLine).isSome),
  ("hypothetical_dependency_cannot_be_forecast", (publish forwardCtx hypotheticalState .forecast).isNone),
  ("published_snapshot_immutable", decide (syntheticState.publications = published.publications)),
  ("published_snapshot_exact", decide (published.publications = [certificate ctx bothCostState .nowcast])),
  ("operational_token_unchanged", decide (syntheticState.operationalToken = opening.operationalToken))
]

end PlanningFixtures

def main : IO Unit := do
  for (name, ok) in PlanningFixtures.checks do
    if ok then IO.println s!"PASS {name}"
    else throw <| IO.userError s!"FAIL {name}"
