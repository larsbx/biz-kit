import Capital

namespace ProducerCapital

def producerUnits : List Owner → Nat
  | [] => 0
  | .producer :: rest => producerUnits rest + 1
  | _ :: rest => producerUnits rest

def poolUnits : List Owner → Nat
  | [] => 0
  | .pool :: rest => poolUnits rest + 1
  | _ :: rest => poolUnits rest

def directUnits : List Owner → Nat
  | [] => 0
  | .investor _ :: rest => directUnits rest + 1
  | _ :: rest => directUnits rest

theorem partition (owners : List Owner) :
    producerUnits owners + poolUnits owners + directUnits owners = owners.length := by
  induction owners with
  | nil => rfl
  | cons owner rest ih =>
    cases owner <;> simp only [producerUnits, poolUnits, directUnits, List.length_cons] <;> omega

def WellFormed (s : State) : Prop := ∀ project, (s.projects project).owners.length = (s.projects project).issued

theorem accepted {ctx s r next} (h : step ctx s r = some next) :
    admitted ctx s r = true ∧ next = commit ctx s r := by
  by_cases allowed : admitted ctx s r = true
  · exact ⟨allowed, by simpa [step, allowed, eq_comm] using h⟩
  · simp [step, allowed] at h

theorem admissionChecks {ctx s r next} (h : step ctx s r = some next) :
    s.usedTx r.tx = false ∧ s.now ≤ ctx.now ∧ ctx.allow s r = true ∧
      authorized ctx s r = true := by
  simpa [admitted, Bool.and_eq_true, and_assoc] using (accepted h).1

theorem shareConservation {ctx s r next} (h : step ctx s r = some next)
    (wf : WellFormed s) (project : Nat) :
    producerUnits (next.projects project).owners + poolUnits (next.projects project).owners +
      directUnits (next.projects project).owners = (s.projects project).issued ∧
    (next.projects project).issued = (s.projects project).issued := by
  rw [partition, (accepted h).2]
  have length := wf project
  cases shape : r.action <;>
    simp only [commit, shape, applyAction, changeProject, update] <;>
    (try split) <;> simp_all [moved]

theorem wellFormedStep {ctx s r next} (h : step ctx s r = some next) (wf : WellFormed s) :
    WellFormed next := by
  intro project
  obtain ⟨count, issued⟩ := shareConservation h wf project
  rw [partition] at count
  exact count.trans issued.symm

theorem purchaseAdmission {ctx s r next source quote authority buyer seller terms}
    (h : step ctx s r = some next)
    (shape : r.action = .purchase source quote authority buyer seller terms) :
    validSale (s.projects terms.project) terms ∧
    signedBy ctx s r authority (.projectAuthority terms.project) = true ∧
    signedBy ctx s r buyer (.holder terms.project .producer) = true ∧
    signedBy ctx s r seller (.holder terms.project terms.seller) = true ∧
    independent ctx buyer seller = true ∧
    appraisalOK ctx s terms quote [authority, buyer, seller] = true ∧
    observed ctx s source (.sale terms) (.projectObserver terms.project)
      ([authority, buyer, seller] ++ ((ctx.valuation quote).map Valuation.grant).toList) = true := by
  simpa [authorized, shape, buyOK, Bool.and_eq_true, and_assoc] using (admissionChecks h).2.2.2

theorem appraisalBinding {ctx s terms quote parties}
    (h : appraisalOK ctx s terms quote parties = true) :
    ∃ v, ctx.valuation quote = some v ∧ active ctx s v.grant (.appraiser terms.project) = true ∧
      parties.all (independent ctx v.grant) = true ∧ v.project = terms.project ∧
      v.version = terms.version ∧ v.currency = terms.currency ∧ 0 < v.perUnit ∧
      v.asOf ≤ ctx.now ∧ ctx.now ≤ v.expires ∧ terms.amount = terms.serials.length * v.perUnit := by
  cases ev : ctx.valuation quote with
  | none => simp [appraisalOK, ev] at h
  | some v =>
    exact ⟨v, rfl, by simpa [appraisalOK, ev, Bool.and_eq_true, and_assoc] using h⟩

theorem observationBinding {ctx s source effect role parties}
    (h : observed ctx s source effect role parties = true) :
    s.journal source = none ∧ ∃ e, ctx.observation source = some e ∧ e.effect = effect ∧
      active ctx s e.grant role = true ∧ parties.all (independent ctx e.grant) = true := by
  cases ev : ctx.observation source with
  | none => simp [observed, ev] at h
  | some e =>
    simp [observed, ev, Bool.and_eq_true, and_assoc] at h
    exact ⟨h.1, e, rfl, by simpa using h.2⟩

theorem purchaseMovesExactly {ctx s r next source quote authority buyer seller terms}
    (h : step ctx s r = some next)
    (shape : r.action = .purchase source quote authority buyer seller terms) (i : Nat) :
    (i ∈ terms.serials →
      (s.projects terms.project).owners[i]? = some terms.seller ∧
      (next.projects terms.project).owners[i]? = some .producer) ∧
    (i ∉ terms.serials →
      (next.projects terms.project).owners[i]? = (s.projects terms.project).owners[i]?) := by
  have owned := (purchaseAdmission h shape).1.2.2.2.2.2
  rw [List.all_eq_true] at owned
  rw [(accepted h).2]
  constructor
  · intro selected
    have exactOwner : (s.projects terms.project).owners[i]? = some terms.seller :=
      of_decide_eq_true (owned i selected)
    exact ⟨exactOwner, by simp [commit, shape, applyAction, changeProject, update,
      moved, selected, exactOwner]⟩
  · intro outside
    simp [commit, shape, applyAction, changeProject, update, moved, outside]

theorem producerOwnershipPersists {ctx s r next} (h : step ctx s r = some next)
    {project i : Nat} (owned : (s.projects project).owners[i]? = some .producer) :
    (next.projects project).owners[i]? = some .producer := by
  rw [(accepted h).2]
  cases shape : r.action <;> simp only [commit, shape, applyAction, changeProject, update] <;>
    (try split) <;> simp_all [moved]

theorem purchasedSerialCannotBeSoldAgain {ctx s r next source quote authority buyer seller terms i}
    (h : step ctx s r = some next) (shape : r.action = .purchase source quote authority buyer seller terms)
    (selected : i ∈ terms.serials) {ctx₂ r₂ next₂ source₂ quote₂ authority₂ buyer₂ seller₂ terms₂}
    (shape₂ : r₂.action = .purchase source₂ quote₂ authority₂ buyer₂ seller₂ terms₂)
    (same : terms₂.project = terms.project) (selected₂ : i ∈ terms₂.serials) :
    step ctx₂ next r₂ ≠ some next₂ := by
  intro later
  have first := ((purchaseMovesExactly h shape i).1 selected).2
  have second := ((purchaseMovesExactly later shape₂ i).1 selected₂).1
  rw [same, first] at second
  exact (purchaseAdmission later shape₂).1.2.2.1 (Option.some.inj second).symm

theorem purchaseAdvancesRevision {ctx s r next source quote authority buyer seller terms}
    (h : step ctx s r = some next) (shape : r.action = .purchase source quote authority buyer seller terms) :
    (next.projects terms.project).version = terms.version + 1 := by
  have rev := (purchaseAdmission h shape).1.1
  simp [(accepted h).2, commit, shape, applyAction, changeProject, update, rev]

theorem projectCapitalIsolation {ctx s r next} (h : step ctx s r = some next) :
    (∀ source authority account amount,
      r.action = .coopDischarge source authority account amount →
      next.projects = s.projects ∧
        ∀ other, other ≠ account → next.coop.balance other = s.coop.balance other) ∧
    (∀ source effect, r.action.effect = some (source, effect) →
      (∀ account amount, effect ≠ .coopDischarge account amount) → next.coop = s.coop) := by
  rw [(accepted h).2]
  constructor
  · intro source authority account amount shape
    refine ⟨by simp [commit, shape, applyAction], ?_⟩
    intro other different
    cases account <;> cases other <;>
      simp_all [commit, applyAction, CoopAccounts.debit, CoopAccounts.balance]
  · intro source effect effectEq nonCoop
    cases shape : r.action <;> simp_all [commit, applyAction, Action.effect, changeProject]
    exact False.elim (nonCoop _ _ effectEq.2.symm)

theorem coopDischargeDebits {ctx s r next source authority account amount}
    (h : step ctx s r = some next) (shape : r.action = .coopDischarge source authority account amount) :
    0 < amount ∧ next.coop.balance account + amount = s.coop.balance account ∧
    signedBy ctx s r authority (.coopAuthority account) = true ∧
    observed ctx s source (.coopDischarge account amount) (.coopObserver account) [authority] = true := by
  have guard := (admissionChecks h).2.2.2
  simp [authorized, shape, Bool.and_eq_true] at guard
  refine ⟨guard.1.1.1, ?_, guard.1.2, guard.2⟩
  have covered := guard.1.1.2
  cases account <;>
    simp [(accepted h).2, commit, shape, applyAction, CoopAccounts.balance, CoopAccounts.debit] at * <;>
    omega

theorem otherProjectsUntouched {ctx s r next} (h : step ctx s r = some next) (other : Nat)
    (different : match r.action with
      | .purchase _ _ _ _ _ terms => other ≠ terms.project
      | .earnings _ _ id .. | .distribute _ _ id .. => other ≠ id
      | _ => True) :
    next.projects other = s.projects other := by
  rw [(accepted h).2]
  cases shape : r.action <;> simp_all [commit, applyAction, changeProject, update]

theorem sourceAvailable {ctx s r next source effect} (h : step ctx s r = some next)
    (binding : r.action.effect = some (source, effect)) :
    s.journal source = none := by
  have auth := (admissionChecks h).2.2.2
  cases shape : r.action <;>
    simp_all [authorized, Action.effect, buyOK, observed, Bool.and_eq_true]

theorem journalRecordsEffect {ctx s r next source effect} (h : step ctx s r = some next)
    (binding : r.action.effect = some (source, effect)) : next.journal source = some effect := by
  simp [(accepted h).2, commit, binding, update]

theorem journalEntryPersists {ctx s r next source effect} (h : step ctx s r = some next)
    (recorded : s.journal source = some effect) : next.journal source = some effect := by
  rw [(accepted h).2]
  cases binding : r.action.effect with
  | none => simpa [commit, binding] using recorded
  | some pair =>
    obtain ⟨key, newEffect⟩ := pair
    have fresh := sourceAvailable h binding
    have distinct : source ≠ key := by
      intro eq
      rw [eq, fresh] at recorded
      contradiction
    simp [commit, binding, update, distinct, recorded]

theorem doubleDischargeRejected {ctx s r next source prior effect}
    (recorded : s.journal source = some prior) (binding : r.action.effect = some (source, effect)) :
    step ctx s r ≠ some next := by
  intro h
  have fresh := sourceAvailable h binding
  rw [fresh] at recorded
  contradiction

theorem transactionRecorded {ctx s r next} (h : step ctx s r = some next) :
    next.usedTx r.tx = true := by
  simp [(accepted h).2, commit, update]

theorem transactionPersists {ctx s r next tx} (h : step ctx s r = some next)
    (spent : s.usedTx tx = true) : next.usedTx tx = true := by
  simp [(accepted h).2, commit, update, spent]

theorem replayRejected {ctx s r next} (spent : s.usedTx r.tx = true) :
    step ctx s r ≠ some next := by
  intro h
  have fresh := (admissionChecks h).1
  simp [spent] at fresh

theorem revokedGrantInactive {ctx s id role} (revoked : s.revoked id = true) :
    active ctx s id role = false := by
  simp [active, revoked]

theorem revocationRecorded {ctx s r next authority target} (h : step ctx s r = some next)
    (shape : r.action = .revoke authority target) :
    signedBy ctx s r authority .revoker = true ∧ next.revoked target = true := by
  have auth := (admissionChecks h).2.2.2
  simp [authorized, shape, Bool.and_eq_true] at auth
  exact ⟨auth.1, by simp [(accepted h).2, commit, shape, applyAction, update]⟩

theorem revocationPersists {ctx s r next grant} (h : step ctx s r = some next)
    (revoked : s.revoked grant = true) : next.revoked grant = true := by
  rw [(accepted h).2]
  cases shape : r.action <;> simp [commit, shape, applyAction, changeProject, update, revoked]

theorem distributionGuarded {ctx s r next source authority project version position asOf allocations}
    (h : step ctx s r = some next)
    (shape : r.action = .distribute source authority project version position asOf allocations) :
    distributionConditions (s.projects project) version ctx.now position asOf allocations ∧
    signedBy ctx s r authority (.projectAuthority project) = true ∧
    observed ctx s source (.distribution project version position asOf allocations)
      (.projectObserver project) [authority] = true ∧
    ctx.allocationAllowed project (s.projects project)
      (.distribution project version position asOf allocations) = true ∧
    ctx.distributionSolvent project (s.projects project) ctx.now = true := by
  simpa [authorized, shape, Bool.and_eq_true, and_assoc] using (admissionChecks h).2.2.2

theorem distributionDebits {ctx s r next source authority project version position asOf allocations}
    (h : step ctx s r = some next)
    (shape : r.action = .distribute source authority project version position asOf allocations) :
    (next.projects project).retained = (s.projects project).retained - (total allocations : Int) ∧
    0 ≤ (next.projects project).retained ∧
    (next.projects project).position.liquid + total allocations = position.liquid ∧
    assetsAtLeast (next.projects project).position 0 := by
  obtain ⟨_, _, _, pos, _, _, profit, assets⟩ := (distributionGuarded h shape).1
  rw [(accepted h).2]
  subst position
  simp [commit, shape, applyAction, changeProject, update, assetsAtLeast] at *
  omega

theorem earningsGuarded {ctx s r next source authority project version net loss}
    (h : step ctx s r = some next) (shape : r.action = .earnings source authority project version net loss) :
    earningsConditions (s.projects project) version net loss ∧
    signedBy ctx s r authority (.projectAuthority project) = true ∧
    observed ctx s source (.earnings project version net loss) (.projectObserver project) [authority] = true ∧
    (0 < net ∨ ctx.allocationAllowed project (s.projects project) (.earnings project version net loss) = true) := by
  simpa [authorized, shape, Bool.and_eq_true, and_assoc] using (admissionChecks h).2.2.2

theorem exactLoss {ctx s r next source authority project version net loss}
    (h : step ctx s r = some next) (shape : r.action = .earnings source authority project version net loss)
    (negative : net < 0) :
    holdersOnly (s.projects project) loss ∧ total loss = net.natAbs ∧
    ctx.allocationAllowed project (s.projects project) (.earnings project version net loss) = true ∧
    (next.projects project).retained = (s.projects project).retained + net ∧
    (next.projects project).position = (s.projects project).position ∧
    next.journal source = some (.earnings project version net loss) := by
  have guards := earningsGuarded h shape
  have casesNet := guards.1.2.2
  have approval := guards.2.2.2.resolve_left (by omega)
  have allocated : holdersOnly (s.projects project) loss ∧ total loss = net.natAbs := by
    rcases casesNet with positive | allocated
    · exact False.elim (by have := positive.1; omega)
    · exact allocated.2
  refine ⟨allocated.1, allocated.2, approval, ?_, ?_, journalRecordsEffect h ?_⟩
  · simp [(accepted h).2, commit, shape, applyAction, changeProject, update]
  · simp [(accepted h).2, commit, shape, applyAction, changeProject, update]
  · simp [shape, Action.effect]

theorem competingSnapshotRejected {ctx s r next source quote authority buyer seller terms}
    (h : step ctx s r = some next) (shape : r.action = .purchase source quote authority buyer seller terms)
    {ctx₂ r₂ next₂ source₂ quote₂ authority₂ buyer₂ seller₂ terms₂}
    (shape₂ : r₂.action = .purchase source₂ quote₂ authority₂ buyer₂ seller₂ terms₂)
    (sameProject : terms₂.project = terms.project) (sameVersion : terms₂.version = terms.version) :
    step ctx₂ next r₂ ≠ some next₂ := by
  intro later
  have old := (purchaseAdmission later shape₂).1.1
  rw [sameProject, sameVersion, purchaseAdvancesRevision h shape] at old
  omega

theorem deficitBlocksDistribution {ctx s r next source authority project version position asOf allocations}
    (shape : r.action = .distribute source authority project version position asOf allocations)
    (deficit : (s.projects project).retained ≤ 0) : step ctx s r ≠ some next := by
  intro h
  obtain ⟨_, _, _, _, _, positive, profit, _⟩ := (distributionGuarded h shape).1
  omega

inductive Reachable (start : State) : State → Prop where
  | start : Reachable start start
  | advance {s next : State} {ctx : Context} {r : Request} :
    Reachable start s → step ctx s r = some next → Reachable start next

theorem reachableWellFormed {s next} (path : Reachable s next) (wf : WellFormed s) :
    WellFormed next := by
  induction path with
  | start => exact wf
  | advance _ h ih => exact wellFormedStep h ih

theorem reachableProducerOwnership {s next} (path : Reachable s next) {project i : Nat}
    (owned : (s.projects project).owners[i]? = some .producer) :
    (next.projects project).owners[i]? = some .producer := by
  induction path with
  | start => exact owned
  | advance _ h ih => exact producerOwnershipPersists h ih

theorem reachableJournalEntry {s next} (path : Reachable s next) {source effect}
    (recorded : s.journal source = some effect) : next.journal source = some effect := by
  induction path with
  | start => exact recorded
  | advance _ h ih => exact journalEntryPersists h ih

end ProducerCapital
