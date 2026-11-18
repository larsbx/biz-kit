import Replay

namespace EconomicPlanning

theorem evidence_accepted {ctx : Context} {s s' : State} {r : EvidenceRequest}
    (h : admitEvidence ctx s r = some s') :
    EvidenceConditions ctx s r ∧ s' = { s with evidence := s.evidence ++ [r.evidence] } := by
  unfold admitEvidence at h
  split at h
  next good => exact ⟨good, (Option.some.inj h).symm⟩
  next => contradiction

theorem allocation_accepted {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s') :
    ∃ r cap, ctx.resource a.resource = some r ∧ r.capacity = some cap ∧
      AllocationConditions ctx s a r cap ∧
      s' = { s with allocations := s.allocations ++ [a] } := by
  unfold allocate at h
  split at h
  next => contradiction
  next r hr =>
    split at h
    next => contradiction
    next cap hc =>
      split at h
      next good => exact ⟨r, cap, hr, hc, good, (Option.some.inj h).symm⟩
      next => contradiction

theorem cost_accepted {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s') :
    CostConditions ctx s line ∧ s' = { s with costs := s.costs ++ [line] } := by
  unfold addCost at h
  split at h
  next good => exact ⟨good, (Option.some.inj h).symm⟩
  next => contradiction

theorem publication_accepted {ctx : Context} {s s' : State} {claim : Claim}
    (h : publish ctx s claim = some s') :
    PublicationConditions ctx s claim ∧
      s' = { s with publications := s.publications ++ [certificate ctx s claim] } := by
  unfold publish at h
  split at h
  next good => exact ⟨good, (Option.some.inj h).symm⟩
  next => contradiction

theorem used_append_one (xs : List Allocation) (a : Allocation) (key : ResourceKey) :
    used (xs ++ [a]) key = used xs key + (if a.resource = key then a.quantity else 0) := by
  induction xs with
  | nil => simp [used]
  | cons x xs ih => simp [used, ih, Nat.add_assoc]

theorem covered_append_one (xs : List CostLine) (line : CostLine) :
    covered (xs ++ [line]) = covered xs ++ line.components := by
  simp [covered]

theorem admitted_exact_source {ctx : Context} {s s' : State} {r : EvidenceRequest}
    (h : admitEvidence ctx s r = some s') :
    r.expectedRef = r.evidence.ref ∧ r.expectedKey = r.evidence.key ∧
      ctx.source r.expectedRef = some r.evidence := by
  have hg := (evidence_accepted h).1
  exact ⟨hg.1, hg.2.1, hg.2.2.1⟩

theorem admitted_scope_and_read {ctx : Context} {s s' : State} {r : EvidenceRequest}
    (h : admitEvidence ctx s r = some s') :
    ctx.canRead r.expectedRef = true ∧ r.evidence.scope = ctx.manifest.scope := by
  have hg := (evidence_accepted h).1
  exact ⟨hg.2.2.2.1, hg.2.2.2.2.1⟩

theorem admitted_available_at_issue {ctx : Context} {s s' : State} {r : EvidenceRequest}
    (h : admitEvidence ctx s r = some s') :
    r.evidence.publishedAt ≤ ctx.manifest.issuedAt ∧
      r.evidence.receivedAt ≤ ctx.manifest.issuedAt := by
  have hg := (evidence_accepted h).1
  exact ⟨hg.2.2.2.2.2.1, hg.2.2.2.2.2.2.1⟩

theorem future_receipt_refused (ctx : Context) (s : State) (r : EvidenceRequest)
    (h : ctx.manifest.issuedAt < r.evidence.receivedAt) : admitEvidence ctx s r = none := by
  simp [admitEvidence, EvidenceConditions, Nat.not_le_of_gt h]

theorem future_publication_refused (ctx : Context) (s : State) (r : EvidenceRequest)
    (h : ctx.manifest.issuedAt < r.evidence.publishedAt) : admitEvidence ctx s r = none := by
  simp [admitEvidence, EvidenceConditions, Nat.not_le_of_gt h]

theorem substituted_key_refused (ctx : Context) (s : State) (r : EvidenceRequest)
    (h : r.expectedKey ≠ r.evidence.key) : admitEvidence ctx s r = none := by
  simp [admitEvidence, EvidenceConditions, h]

theorem substituted_revision_refused (ctx : Context) (s : State) (r : EvidenceRequest)
    (h : r.expectedRef ≠ r.evidence.ref) : admitEvidence ctx s r = none := by
  simp [admitEvidence, EvidenceConditions, h]

theorem repeated_evidence_refused (ctx : Context) (s : State) (r : EvidenceRequest)
    (h : r.evidence.ref ∈ s.evidence.map Evidence.ref) : admitEvidence ctx s r = none := by
  simp [admitEvidence, EvidenceConditions, h]

theorem unknown_capacity_refused (ctx : Context) (s : State) (a : Allocation)
    (r : Resource) (hr : ctx.resource a.resource = some r) (hc : r.capacity = none) :
    allocate ctx s a = none := by
  simp [allocate, hr, hc]

theorem zero_capacity_refused (ctx : Context) (s : State) (a : Allocation)
    (r : Resource) (hr : ctx.resource a.resource = some r) (hc : r.capacity = some 0) :
    allocate ctx s a = none := by
  simp only [allocate, hr, hc]
  split
  next hg =>
    have hpos := hg.2.2.2.2.2.2.1
    have hbound := hg.2.2.2.2.2.2.2
    omega
  next => rfl

theorem allocation_preserves_identity {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s') :
    ∃ r cap, ctx.resource a.resource = some r ∧ r.capacity = some cap ∧
      a.resource.scope = ctx.manifest.scope ∧ a.source = r.source ∧ a.signal = r.signal := by
  obtain ⟨r, cap, hr, hc, hg, _⟩ := allocation_accepted h
  exact ⟨r, cap, hr, hc, hg.1, hg.2.1, hg.2.2.1⟩

theorem allocation_source_quantity_and_time {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s') :
    ∃ e ∈ s.evidence, e.ref = a.source ∧ e.key = a.signal ∧
      e.effectiveFrom ≤ a.resource.bucket ∧ a.resource.bucket < e.effectiveUntil ∧
      ∃ cap, e.quantity = some cap ∧ used s.allocations a.resource + a.quantity ≤ cap := by
  obtain ⟨r, cap, _, hc, hg, _⟩ := allocation_accepted h
  have hl := hg.2.2.2.1
  simp only [linked, List.any_eq_true, decide_eq_true_eq] at hl
  obtain ⟨e, he, href, hkey, hquantity, hstart, hend, _⟩ := hl
  exact ⟨e, he, href.trans hg.2.1.symm, hkey.trans hg.2.2.1.symm,
    hstart, hend, cap, hquantity.trans hc, hg.2.2.2.2.2.2.2⟩

theorem allocation_in_horizon {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s') :
    ctx.manifest.horizonStart ≤ a.resource.bucket ∧ a.resource.bucket < ctx.manifest.horizonEnd := by
  obtain ⟨_, _, _, _, hg, _⟩ := allocation_accepted h
  exact ⟨hg.2.2.2.2.1, hg.2.2.2.2.2.1⟩

theorem allocation_exact_consumption {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s') :
    used s'.allocations a.resource = used s.allocations a.resource + a.quantity := by
  obtain ⟨_, _, _, _, _, rfl⟩ := allocation_accepted h
  simp [used_append_one]

theorem allocation_other_resource_unchanged {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s') (key : ResourceKey) (hne : a.resource ≠ key) :
    used s'.allocations key = used s.allocations key := by
  obtain ⟨_, _, _, _, _, rfl⟩ := allocation_accepted h
  simp [used_append_one, hne]

theorem allocation_conservation {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s') :
    ∃ r cap, ctx.resource a.resource = some r ∧ r.capacity = some cap ∧
      used s'.allocations a.resource ≤ cap ∧
      cap - used s'.allocations a.resource + used s'.allocations a.resource = cap := by
  obtain ⟨r, cap, hr, hc, hg, _⟩ := allocation_accepted h
  have hbound : used s'.allocations a.resource ≤ cap := by
    rw [allocation_exact_consumption h]
    exact hg.2.2.2.2.2.2.2
  exact ⟨r, cap, hr, hc, hbound, Nat.sub_add_cancel hbound⟩

theorem accepted_cost_currency {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s') : line.currency = ctx.manifest.currency :=
  (cost_accepted h).1.1

theorem accepted_cost_disjoint {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s') :
    line.components ≠ [] ∧ line.components.Nodup ∧
      ∀ component ∈ line.components, component ∉ covered s.costs := by
  have hg := (cost_accepted h).1
  exact ⟨hg.2.1, hg.2.2.1, hg.2.2.2.1⟩

theorem accepted_cost_source_amount {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s') :
    ∃ e ∈ s.evidence, e.ref = line.source ∧ e.key = line.signal ∧
      e.quantity = some line.minorUnits ∧ e.key.currency = line.currency ∧
      e.effectiveFrom ≤ line.atTime ∧ line.atTime < e.effectiveUntil := by
  have hl := (cost_accepted h).1.2.2.2.2.1
  simp only [costLinked, List.any_eq_true, decide_eq_true_eq] at hl
  obtain ⟨e, he, href, hkey, hq, hcurrency, hstart, hend, _⟩ := hl
  exact ⟨e, he, href, hkey, hq, hcurrency, hstart, hend⟩

theorem allocation_physical_dimension {ctx : Context} {s s' : State} {a : Allocation}
    (h : allocate ctx s a = some s') : a.signal.measure = .physicalQuantity := by
  obtain ⟨r, cap, _, _, hg, _⟩ := allocation_accepted h
  have hl := hg.2.2.2.1
  simp only [linked, List.any_eq_true, decide_eq_true_eq] at hl
  obtain ⟨e, _, _, hkey, _, _, _, hm⟩ := hl
  rw [hg.2.2.1, ← hkey]
  exact hm

theorem accepted_cost_monetary_dimension {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s') :
    line.signal.measure = .moneyMinorUnits ∧ line.signal.unit = "minor-unit" := by
  have hl := (cost_accepted h).1.2.2.2.2.1
  simp only [costLinked, List.any_eq_true, decide_eq_true_eq] at hl
  obtain ⟨e, _, _, hkey, _, _, _, _, hm, hu⟩ := hl
  rw [← hkey]
  exact ⟨hm, hu⟩

theorem overlapping_component_refused (ctx : Context) (s : State) (line : CostLine)
    (component : String) (ha : component ∈ line.components) (hb : component ∈ covered s.costs) :
    addCost ctx s line = none := by
  unfold addCost
  split
  next hg => exact False.elim (hg.2.2.2.1 component ha hb)
  next => rfl

theorem accepted_cost_source_fresh {ctx : Context} {s s' : State} {line : CostLine}
    (h : addCost ctx s line = some s') : line.source ∉ s.costs.map CostLine.source :=
  (cost_accepted h).1.2.2.2.2.2.2.2

theorem cost_source_replay_refused (ctx : Context) (s : State) (line : CostLine)
    (h : line.source ∈ s.costs.map CostLine.source) : addCost ctx s line = none := by
  simp [addCost, CostConditions, h]

theorem observed_publication_refused (ctx : Context) (s : State) : publish ctx s .observed = none := by
  simp [publish, PublicationConditions]

theorem nonobserved_dependency_forces_scenario {ctx : Context} {s s' : State} {claim : Claim}
    (h : publish ctx s claim = some s') (e : Evidence) (he : e ∈ s.evidence)
    (ho : e.origin ≠ .observed) : claim = .scenario := by
  have hchoice := (publication_accepted h).1.2.2.1
  rcases hchoice with hall | hscenario
  · have allOrigins : ∀ x ∈ s.evidence, x.origin = .observed := by
      simpa only [allObserved, List.all_eq_true, decide_eq_true_eq] using hall
    have hon := allOrigins e he
    exact False.elim (ho hon)
  · exact hscenario

theorem published_exact_snapshot (ctx : Context) (s : State) (claim : Claim) :
    (certificate ctx s claim).manifest = ctx.manifest ∧
    (certificate ctx s claim).evidence = s.evidence ∧
    (certificate ctx s claim).allocations = s.allocations ∧
    (certificate ctx s claim).costs = s.costs := ⟨rfl, rfl, rfl, rfl⟩

theorem published_claim_horizon {ctx : Context} {s s' : State} {claim : Claim}
    (h : publish ctx s claim = some s') : ClaimHorizon ctx.manifest claim := by
  exact (publication_accepted h).1.2.2.2.2.2.2.2.2.2

theorem published_nowcast_contains_issue {ctx : Context} {s s' : State}
    (h : publish ctx s .nowcast = some s') :
    ctx.manifest.horizonStart ≤ ctx.manifest.issuedAt ∧
      ctx.manifest.issuedAt < ctx.manifest.horizonEnd := published_claim_horizon h

theorem published_forecast_after_issue {ctx : Context} {s s' : State}
    (h : publish ctx s .forecast = some s') :
    ctx.manifest.issuedAt < ctx.manifest.horizonStart := published_claim_horizon h

theorem step_operational_token {ctx : Context} {s s' : State} {action : Action}
    (h : step ctx s action = some s') : s'.operationalToken = s.operationalToken := by
  cases action with
  | evidence r => obtain ⟨_, rfl⟩ := evidence_accepted h; rfl
  | allocate a => obtain ⟨_, _, _, _, _, rfl⟩ := allocation_accepted h; rfl
  | cost line => obtain ⟨_, rfl⟩ := cost_accepted h; rfl
  | publish claim => obtain ⟨_, rfl⟩ := publication_accepted h; rfl

theorem step_publications_prefix {ctx : Context} {s s' : State} {action : Action}
    (h : step ctx s action = some s') : s.publications.IsPrefix s'.publications := by
  cases action with
  | evidence r => obtain ⟨_, rfl⟩ := evidence_accepted h; exact ⟨[], by simp⟩
  | allocate a => obtain ⟨_, _, _, _, _, rfl⟩ := allocation_accepted h; exact ⟨[], by simp⟩
  | cost line => obtain ⟨_, rfl⟩ := cost_accepted h; exact ⟨[], by simp⟩
  | publish claim => obtain ⟨_, rfl⟩ := publication_accepted h; exact ⟨[_], rfl⟩

theorem trace_operational_token {ctx : Context} {s s' : State} (h : Trace ctx s s') :
    s'.operationalToken = s.operationalToken := by
  induction h with
  | refl => rfl
  | next _ _ accepted ih => exact (step_operational_token accepted).trans ih

theorem trace_publications_prefix {ctx : Context} {s s' : State} (h : Trace ctx s s') :
    s.publications.IsPrefix s'.publications := by
  induction h with
  | refl => exact ⟨[], by simp⟩
  | next _ _ accepted ih => exact ih.trans (step_publications_prefix accepted)

theorem trace_preserves_published_certificate {ctx : Context} {s s' : State}
    (h : Trace ctx s s') (cert : Certificate) (hc : cert ∈ s.publications) :
    cert ∈ s'.publications := by
  obtain ⟨tail, ht⟩ := trace_publications_prefix h
  rw [← ht]
  exact List.mem_append_left _ hc

theorem initial_capacity_safe (ctx : Context) (token : String) : CapacitySafe ctx (initial token) := by
  intro key
  unfold initial
  cases ctx.resource key with
  | none => rfl
  | some r => cases hcap : r.capacity <;> simp [hcap, used]

theorem allocation_preserves_capacity {ctx : Context} {s s' : State} {a : Allocation}
    (safe : CapacitySafe ctx s) (h : allocate ctx s a = some s') : CapacitySafe ctx s' := by
  obtain ⟨r, cap, hr, hc, hg, heq⟩ := allocation_accepted h
  intro key
  by_cases same : a.resource = key
  · subst key
    simp only [hr, hc]
    rw [allocation_exact_consumption h]
    exact hg.2.2.2.2.2.2.2
  · have hu := allocation_other_resource_unchanged h key same
    have hs := safe key
    unfold CapacitySafe at safe
    cases hk : ctx.resource key with
    | none => simpa only [hk, hu] using hs
    | some r' =>
      cases hcap : r'.capacity with
      | none => simpa only [hk, hcap, hu] using hs
      | some cap' => simpa only [hk, hcap, hu] using hs

theorem step_preserves_capacity {ctx : Context} {s s' : State} {action : Action}
    (safe : CapacitySafe ctx s) (h : step ctx s action = some s') : CapacitySafe ctx s' := by
  cases action with
  | evidence r => obtain ⟨_, rfl⟩ := evidence_accepted h; exact safe
  | allocate a => exact allocation_preserves_capacity safe h
  | cost line => obtain ⟨_, rfl⟩ := cost_accepted h; exact safe
  | publish claim => obtain ⟨_, rfl⟩ := publication_accepted h; exact safe

theorem trace_preserves_capacity {ctx : Context} {s s' : State}
    (safe : CapacitySafe ctx s) (h : Trace ctx s s') : CapacitySafe ctx s' := by
  induction h with
  | refl => exact safe
  | next _ _ accepted ih => exact step_preserves_capacity ih accepted

theorem trace_capacity_conservation {ctx : Context} {token : String} {s : State}
    (h : Trace ctx (initial token) s) (key : ResourceKey) (r : Resource) (cap : Nat)
    (hr : ctx.resource key = some r) (hc : r.capacity = some cap) :
    used s.allocations key ≤ cap ∧ cap - used s.allocations key + used s.allocations key = cap := by
  have hs := trace_preserves_capacity (initial_capacity_safe ctx token) h key
  simp only [hr, hc] at hs
  exact ⟨hs, Nat.sub_add_cancel hs⟩

theorem trace_unknown_capacity_unused {ctx : Context} {token : String} {s : State}
    (h : Trace ctx (initial token) s) (key : ResourceKey) (r : Resource)
    (hr : ctx.resource key = some r) (hc : r.capacity = none) : used s.allocations key = 0 := by
  have hs := trace_preserves_capacity (initial_capacity_safe ctx token) h key
  simpa only [hr, hc] using hs

theorem initial_sources_safe (ctx : Context) (token : String) : SourcesSafe ctx (initial token) := by
  simp [SourcesSafe, initial]

theorem evidence_preserves_sources {ctx : Context} {s s' : State} {r : EvidenceRequest}
    (safe : SourcesSafe ctx s) (h : admitEvidence ctx s r = some s') : SourcesSafe ctx s' := by
  obtain ⟨hg, rfl⟩ := evidence_accepted h
  intro e he
  simp only [List.mem_append, List.mem_singleton] at he
  rcases he with old | rfl
  · exact safe e old
  · rcases hg with ⟨href, _, hsource, hread, hscope, hpub, hrecv, _⟩
    exact ⟨by simpa only [href] using hsource, by simpa only [href] using hread,
      hscope, hpub, hrecv⟩

theorem step_preserves_sources {ctx : Context} {s s' : State} {action : Action}
    (safe : SourcesSafe ctx s) (h : step ctx s action = some s') : SourcesSafe ctx s' := by
  cases action with
  | evidence r => exact evidence_preserves_sources safe h
  | allocate a => obtain ⟨_, _, _, _, _, rfl⟩ := allocation_accepted h; exact safe
  | cost line => obtain ⟨_, rfl⟩ := cost_accepted h; exact safe
  | publish claim => obtain ⟨_, rfl⟩ := publication_accepted h; exact safe

theorem trace_sources_available {ctx : Context} {token : String} {s : State}
    (h : Trace ctx (initial token) s) : SourcesSafe ctx s := by
  have generic : ∀ {first last}, Trace ctx first last → SourcesSafe ctx first → SourcesSafe ctx last := by
    intro first last ht
    induction ht with
    | refl => exact id
    | next _ _ accepted ih => exact fun hs => step_preserves_sources (ih hs) accepted
  exact generic h (initial_sources_safe ctx token)

theorem initial_costs_safe (ctx : Context) (token : String) : CostsSafe ctx (initial token) := by
  simp [CostsSafe, covered, initial]

theorem cost_preserves_disjoint_currency {ctx : Context} {s s' : State} {line : CostLine}
    (safe : CostsSafe ctx s) (h : addCost ctx s line = some s') : CostsSafe ctx s' := by
  obtain ⟨hg, rfl⟩ := cost_accepted h
  constructor
  · rw [covered_append_one, List.nodup_append]
    refine ⟨safe.1, hg.2.2.1, ?_⟩
    intro a ha b hb hab
    exact hg.2.2.2.1 b hb (hab ▸ ha)
  · intro c hc
    simp only [List.mem_append, List.mem_singleton] at hc
    rcases hc with old | rfl
    · exact safe.2 c old
    · exact hg.1

theorem step_preserves_costs {ctx : Context} {s s' : State} {action : Action}
    (safe : CostsSafe ctx s) (h : step ctx s action = some s') : CostsSafe ctx s' := by
  cases action with
  | evidence r => obtain ⟨_, rfl⟩ := evidence_accepted h; exact safe
  | allocate a => obtain ⟨_, _, _, _, _, rfl⟩ := allocation_accepted h; exact safe
  | cost line => exact cost_preserves_disjoint_currency safe h
  | publish claim => obtain ⟨_, rfl⟩ := publication_accepted h; exact safe

theorem trace_costs_disjoint_currency {ctx : Context} {token : String} {s : State}
    (h : Trace ctx (initial token) s) : CostsSafe ctx s := by
  have generic : ∀ {first last}, Trace ctx first last → CostsSafe ctx first → CostsSafe ctx last := by
    intro first last ht
    induction ht with
    | refl => exact id
    | next _ _ accepted ih => exact fun hs => step_preserves_costs (ih hs) accepted
  exact generic h (initial_costs_safe ctx token)

theorem trace_trans {ctx : Context} {first middle last : State}
    (before : Trace ctx first middle) (after : Trace ctx middle last) : Trace ctx first last := by
  induction after with
  | refl => exact before
  | next _ action accepted ih => exact .next ih action accepted

theorem replayFrom_success_trace {ctx : Context} {first last : State} {actions : List Action}
    (h : replayFrom ctx first actions = some last) : Trace ctx first last := by
  induction actions generalizing first with
  | nil =>
    simp only [replayFrom, Option.some.injEq] at h
    subst last
    exact .refl first
  | cons action rest ih =>
    cases accepted : step ctx first action with
    | none => simp [replayFrom, accepted] at h
    | some next =>
      have tail : replayFrom ctx next rest = some last := by
        simpa only [replayFrom, accepted, Option.bind_some] using h
      exact trace_trans (.next (.refl first) action accepted) (ih tail)

theorem replay_success_trace {ctx : Context} {token : String} {actions : List Action} {s : State}
    (h : replay ctx token actions = some s) : Trace ctx (initial token) s :=
  replayFrom_success_trace h

theorem replayFrom_append (ctx : Context) (s : State) (before after : List Action) :
    replayFrom ctx s (before ++ after) =
      (replayFrom ctx s before).bind (fun middle => replayFrom ctx middle after) := by
  induction before generalizing s with
  | nil => rfl
  | cons action rest ih =>
    cases hs : step ctx s action <;> simp [replayFrom, hs, ih]

theorem replay_rejected_prefix {ctx : Context} {token : String} {before after : List Action}
    (h : replay ctx token before = none) : replay ctx token (before ++ after) = none := by
  simp only [replay, replayFrom_append] at *
  simp [h]

theorem replay_initial_empty (ctx : Context) (token : String) :
    replay ctx token [] = some (initial token) := rfl

theorem replay_capacity_safe {ctx : Context} {token : String} {actions : List Action} {s : State}
    (h : replay ctx token actions = some s) : CapacitySafe ctx s :=
  trace_preserves_capacity (initial_capacity_safe ctx token) (replay_success_trace h)

theorem replay_capacity_conservation {ctx : Context} {token : String}
    {actions : List Action} {s : State} (h : replay ctx token actions = some s)
    (key : ResourceKey) (r : Resource) (cap : Nat)
    (hr : ctx.resource key = some r) (hc : r.capacity = some cap) :
    used s.allocations key ≤ cap ∧ cap - used s.allocations key + used s.allocations key = cap :=
  trace_capacity_conservation (replay_success_trace h) key r cap hr hc

theorem replay_unknown_capacity_unused {ctx : Context} {token : String}
    {actions : List Action} {s : State} (h : replay ctx token actions = some s)
    (key : ResourceKey) (r : Resource) (hr : ctx.resource key = some r)
    (hc : r.capacity = none) : used s.allocations key = 0 :=
  trace_unknown_capacity_unused (replay_success_trace h) key r hr hc

theorem replay_sources_available {ctx : Context} {token : String} {actions : List Action} {s : State}
    (h : replay ctx token actions = some s) : SourcesSafe ctx s :=
  trace_sources_available (replay_success_trace h)

theorem replay_costs_disjoint_currency {ctx : Context} {token : String}
    {actions : List Action} {s : State} (h : replay ctx token actions = some s) : CostsSafe ctx s :=
  trace_costs_disjoint_currency (replay_success_trace h)

theorem replay_operational_token {ctx : Context} {token : String} {actions : List Action} {s : State}
    (h : replay ctx token actions = some s) : s.operationalToken = token :=
  trace_operational_token (replay_success_trace h)

theorem replayFrom_publications_prefix {ctx : Context} {first last : State} {actions : List Action}
    (h : replayFrom ctx first actions = some last) :
    first.publications.IsPrefix last.publications :=
  trace_publications_prefix (replayFrom_success_trace h)

theorem replayFrom_preserves_published_certificate {ctx : Context}
    {first last : State} {actions : List Action} (h : replayFrom ctx first actions = some last)
    (cert : Certificate) (hc : cert ∈ first.publications) : cert ∈ last.publications :=
  trace_preserves_published_certificate (replayFrom_success_trace h) cert hc

end EconomicPlanning
