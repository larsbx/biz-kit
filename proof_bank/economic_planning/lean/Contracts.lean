import Proofs

/-! Fixed expected API propositions, independently compiled against the theorem
exports. This module does not obtain types by inspecting declarations. Weakening
a theorem to True must fail these literal, checked signatures. -/

-- Premise names document the expected types; their values are passed by @ below.
set_option linter.unusedVariables false

open EconomicPlanning

-- evidence_accepted
example : ∀ {ctx : Context} {s s' : State} {r : EvidenceRequest}
    (h : admitEvidence ctx s r = some s'),
    EvidenceConditions ctx s r ∧ s' = { s with evidence := s.evidence ++ [r.evidence] } := @evidence_accepted

-- allocation_accepted
example : ∀ {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s'),
    ∃ r cap, ctx.resource a.resource = some r ∧ r.capacity = some cap ∧
      AllocationConditions ctx s a r cap ∧
      s' = { s with allocations := s.allocations ++ [a] } := @allocation_accepted

-- cost_accepted
example : ∀ {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s'),
    CostConditions ctx s line ∧ s' = { s with costs := s.costs ++ [line] } := @cost_accepted

-- publication_accepted
example : ∀ {ctx : Context} {s s' : State} {claim : Claim}
    (h : publish ctx s claim = some s'),
    PublicationConditions ctx s claim ∧
      s' = { s with publications := s.publications ++ [certificate ctx s claim] } := @publication_accepted

-- used_append_one
example : ∀ (xs : List Allocation) (a : Allocation) (key : ResourceKey),
    used (xs ++ [a]) key = used xs key + (if a.resource = key then a.quantity else 0) := @used_append_one

-- covered_append_one
example : ∀ (xs : List CostLine) (line : CostLine),
    covered (xs ++ [line]) = covered xs ++ line.components := @covered_append_one

-- admitted_exact_source
example : ∀ {ctx : Context} {s s' : State} {r : EvidenceRequest}
    (h : admitEvidence ctx s r = some s'),
    r.expectedRef = r.evidence.ref ∧ r.expectedKey = r.evidence.key ∧
      ctx.source r.expectedRef = some r.evidence := @admitted_exact_source

-- admitted_scope_and_read
example : ∀ {ctx : Context} {s s' : State} {r : EvidenceRequest}
    (h : admitEvidence ctx s r = some s'),
    ctx.canRead r.expectedRef = true ∧ r.evidence.scope = ctx.manifest.scope := @admitted_scope_and_read

-- admitted_available_at_issue
example : ∀ {ctx : Context} {s s' : State} {r : EvidenceRequest}
    (h : admitEvidence ctx s r = some s'),
    r.evidence.publishedAt ≤ ctx.manifest.issuedAt ∧
      r.evidence.receivedAt ≤ ctx.manifest.issuedAt := @admitted_available_at_issue

-- future_receipt_refused
example : ∀ (ctx : Context) (s : State) (r : EvidenceRequest)
    (h : ctx.manifest.issuedAt < r.evidence.receivedAt),
    admitEvidence ctx s r = none := @future_receipt_refused

-- future_publication_refused
example : ∀ (ctx : Context) (s : State) (r : EvidenceRequest)
    (h : ctx.manifest.issuedAt < r.evidence.publishedAt),
    admitEvidence ctx s r = none := @future_publication_refused

-- substituted_key_refused
example : ∀ (ctx : Context) (s : State) (r : EvidenceRequest)
    (h : r.expectedKey ≠ r.evidence.key),
    admitEvidence ctx s r = none := @substituted_key_refused

-- substituted_revision_refused
example : ∀ (ctx : Context) (s : State) (r : EvidenceRequest)
    (h : r.expectedRef ≠ r.evidence.ref),
    admitEvidence ctx s r = none := @substituted_revision_refused

-- repeated_evidence_refused
example : ∀ (ctx : Context) (s : State) (r : EvidenceRequest)
    (h : r.evidence.ref ∈ s.evidence.map Evidence.ref),
    admitEvidence ctx s r = none := @repeated_evidence_refused

-- unknown_capacity_refused
example : ∀ (ctx : Context) (s : State) (a : Allocation)
    (r : Resource) (hr : ctx.resource a.resource = some r) (hc : r.capacity = none),
    allocate ctx s a = none := @unknown_capacity_refused

-- zero_capacity_refused
example : ∀ (ctx : Context) (s : State) (a : Allocation)
    (r : Resource) (hr : ctx.resource a.resource = some r) (hc : r.capacity = some 0),
    allocate ctx s a = none := @zero_capacity_refused

-- allocation_preserves_identity
example : ∀ {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s'),
    ∃ r cap, ctx.resource a.resource = some r ∧ r.capacity = some cap ∧
      a.resource.scope = ctx.manifest.scope ∧ a.source = r.source ∧ a.signal = r.signal := @allocation_preserves_identity

-- allocation_source_quantity_and_time
example : ∀ {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s'),
    ∃ e ∈ s.evidence, e.ref = a.source ∧ e.key = a.signal ∧
      e.effectiveFrom ≤ a.resource.bucket ∧ a.resource.bucket < e.effectiveUntil ∧
      ∃ cap, e.quantity = some cap ∧ used s.allocations a.resource + a.quantity ≤ cap := @allocation_source_quantity_and_time

-- allocation_in_horizon
example : ∀ {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s'),
    ctx.manifest.horizonStart ≤ a.resource.bucket ∧ a.resource.bucket < ctx.manifest.horizonEnd := @allocation_in_horizon

-- allocation_exact_consumption
example : ∀ {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s'),
    used s'.allocations a.resource = used s.allocations a.resource + a.quantity := @allocation_exact_consumption

-- allocation_other_resource_unchanged
example : ∀ {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s') (key : ResourceKey) (hne : a.resource ≠ key),
    used s'.allocations key = used s.allocations key := @allocation_other_resource_unchanged

-- allocation_conservation
example : ∀ {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s'),
    ∃ r cap, ctx.resource a.resource = some r ∧ r.capacity = some cap ∧
      used s'.allocations a.resource ≤ cap ∧
      cap - used s'.allocations a.resource + used s'.allocations a.resource = cap := @allocation_conservation

-- accepted_cost_currency
example : ∀ {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s'),
    line.currency = ctx.manifest.currency := @accepted_cost_currency

-- accepted_cost_disjoint
example : ∀ {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s'),
    line.components ≠ [] ∧ line.components.Nodup ∧
      ∀ component ∈ line.components, component ∉ covered s.costs := @accepted_cost_disjoint

-- accepted_cost_source_amount
example : ∀ {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s'),
    ∃ e ∈ s.evidence, e.ref = line.source ∧ e.key = line.signal ∧
      e.quantity = some line.minorUnits ∧ e.key.currency = line.currency ∧
      e.effectiveFrom ≤ line.atTime ∧ line.atTime < e.effectiveUntil := @accepted_cost_source_amount

-- allocation_physical_dimension
example : ∀ {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s'),
    a.signal.measure = .physicalQuantity := @allocation_physical_dimension

-- accepted_cost_monetary_dimension
example : ∀ {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s'),
    line.signal.measure = .moneyMinorUnits ∧ line.signal.unit = "minor-unit" := @accepted_cost_monetary_dimension

-- overlapping_component_refused
example : ∀ (ctx : Context) (s : State) (line : CostLine)
    (component : String) (ha : component ∈ line.components) (hb : component ∈ covered s.costs),
    addCost ctx s line = none := @overlapping_component_refused

-- accepted_cost_source_fresh
example : ∀ {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s'),
    line.source ∉ s.costs.map CostLine.source := @accepted_cost_source_fresh

-- cost_source_replay_refused
example : ∀ (ctx : Context) (s : State) (line : CostLine)
    (h : line.source ∈ s.costs.map CostLine.source),
    addCost ctx s line = none := @cost_source_replay_refused

-- observed_publication_refused
example : ∀ (ctx : Context) (s : State),
    publish ctx s .observed = none := @observed_publication_refused

-- nonobserved_dependency_forces_scenario
example : ∀ {ctx : Context} {s s' : State} {claim : Claim}
    (h : publish ctx s claim = some s') (e : Evidence) (he : e ∈ s.evidence)
    (ho : e.origin ≠ .observed),
    claim = .scenario := @nonobserved_dependency_forces_scenario

-- published_exact_snapshot
example : ∀ (ctx : Context) (s : State) (claim : Claim),
    (certificate ctx s claim).manifest = ctx.manifest ∧
    (certificate ctx s claim).evidence = s.evidence ∧
    (certificate ctx s claim).allocations = s.allocations ∧
    (certificate ctx s claim).costs = s.costs := @published_exact_snapshot

-- published_claim_horizon
example : ∀ {ctx : Context} {s s' : State} {claim : Claim}
    (h : publish ctx s claim = some s'),
    ClaimHorizon ctx.manifest claim := @published_claim_horizon

-- published_nowcast_contains_issue
example : ∀ {ctx : Context} {s s' : State}
    (h : publish ctx s .nowcast = some s'),
    ctx.manifest.horizonStart ≤ ctx.manifest.issuedAt ∧
      ctx.manifest.issuedAt < ctx.manifest.horizonEnd := @published_nowcast_contains_issue

-- published_forecast_after_issue
example : ∀ {ctx : Context} {s s' : State}
    (h : publish ctx s .forecast = some s'),
    ctx.manifest.issuedAt < ctx.manifest.horizonStart := @published_forecast_after_issue

-- step_operational_token
example : ∀ {ctx : Context} {s s' : State} {action : Action}
    (h : step ctx s action = some s'),
    s'.operationalToken = s.operationalToken := @step_operational_token

-- step_publications_prefix
example : ∀ {ctx : Context} {s s' : State} {action : Action}
    (h : step ctx s action = some s'),
    s.publications.IsPrefix s'.publications := @step_publications_prefix

-- trace_operational_token
example : ∀ {ctx : Context} {s s' : State} (h : Trace ctx s s'),
    s'.operationalToken = s.operationalToken := @trace_operational_token

-- trace_publications_prefix
example : ∀ {ctx : Context} {s s' : State} (h : Trace ctx s s'),
    s.publications.IsPrefix s'.publications := @trace_publications_prefix

-- trace_preserves_published_certificate
example : ∀ {ctx : Context} {s s' : State}
    (h : Trace ctx s s') (cert : Certificate) (hc : cert ∈ s.publications),
    cert ∈ s'.publications := @trace_preserves_published_certificate

-- initial_capacity_safe
example : ∀ (ctx : Context) (token : String),
    CapacitySafe ctx (initial token) := @initial_capacity_safe

-- allocation_preserves_capacity
example : ∀ {ctx : Context} {s s' : State} {a : Allocation}
    (safe : CapacitySafe ctx s) (h : allocate ctx s a = some s'),
    CapacitySafe ctx s' := @allocation_preserves_capacity

-- step_preserves_capacity
example : ∀ {ctx : Context} {s s' : State} {action : Action}
    (safe : CapacitySafe ctx s) (h : step ctx s action = some s'),
    CapacitySafe ctx s' := @step_preserves_capacity

-- trace_preserves_capacity
example : ∀ {ctx : Context} {s s' : State}
    (safe : CapacitySafe ctx s) (h : Trace ctx s s'),
    CapacitySafe ctx s' := @trace_preserves_capacity

-- trace_capacity_conservation
example : ∀ {ctx : Context} {token : String} {s : State}
    (h : Trace ctx (initial token) s) (key : ResourceKey) (r : Resource) (cap : Nat)
    (hr : ctx.resource key = some r) (hc : r.capacity = some cap),
    used s.allocations key ≤ cap ∧ cap - used s.allocations key + used s.allocations key = cap := @trace_capacity_conservation

-- trace_unknown_capacity_unused
example : ∀ {ctx : Context} {token : String} {s : State}
    (h : Trace ctx (initial token) s) (key : ResourceKey) (r : Resource)
    (hr : ctx.resource key = some r) (hc : r.capacity = none),
    used s.allocations key = 0 := @trace_unknown_capacity_unused

-- initial_sources_safe
example : ∀ (ctx : Context) (token : String),
    SourcesSafe ctx (initial token) := @initial_sources_safe

-- evidence_preserves_sources
example : ∀ {ctx : Context} {s s' : State} {r : EvidenceRequest}
    (safe : SourcesSafe ctx s) (h : admitEvidence ctx s r = some s'),
    SourcesSafe ctx s' := @evidence_preserves_sources

-- step_preserves_sources
example : ∀ {ctx : Context} {s s' : State} {action : Action}
    (safe : SourcesSafe ctx s) (h : step ctx s action = some s'),
    SourcesSafe ctx s' := @step_preserves_sources

-- trace_sources_available
example : ∀ {ctx : Context} {token : String} {s : State}
    (h : Trace ctx (initial token) s),
    SourcesSafe ctx s := @trace_sources_available

-- initial_costs_safe
example : ∀ (ctx : Context) (token : String),
    CostsSafe ctx (initial token) := @initial_costs_safe

-- cost_preserves_disjoint_currency
example : ∀ {ctx : Context} {s s' : State} {line : CostLine}
    (safe : CostsSafe ctx s) (h : addCost ctx s line = some s'),
    CostsSafe ctx s' := @cost_preserves_disjoint_currency

-- step_preserves_costs
example : ∀ {ctx : Context} {s s' : State} {action : Action}
    (safe : CostsSafe ctx s) (h : step ctx s action = some s'),
    CostsSafe ctx s' := @step_preserves_costs

-- trace_costs_disjoint_currency
example : ∀ {ctx : Context} {token : String} {s : State}
    (h : Trace ctx (initial token) s),
    CostsSafe ctx s := @trace_costs_disjoint_currency
