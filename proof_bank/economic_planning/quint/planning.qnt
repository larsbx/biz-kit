// Independent finite abstraction of the inert planning contract. All data are synthetic.
// The source catalog and can-read answers are trusted inputs, not authentication proofs.
module planning {
  type Ref = { source: int, revision: int }
  type SignalKey = { measure: str, family: str, subject: str, material: str, grade: str, form: str, unit: str,
    currency: str, location: str, instrument: str, maturity: int }
  type Evidence = { ref: Ref, key: SignalKey, scope: str, published: int,
    received: int, effectiveFrom: int, effectiveUntil: int, origin: str, quantityKnown: bool, quantity: int, payload: str }
  type EvidenceRequest = { expectedRef: Ref, expectedKey: SignalKey, actual: Evidence }
  type ResourceKey = { scope: str, constraint: int, bucket: int }
  type Resource = { key: ResourceKey, source: Ref, signal: SignalKey,
    known: bool, capacity: int }
  type Allocation = { key: ResourceKey, source: Ref, signal: SignalKey,
    mode: str, quantity: int }
  type Cost = { source: Ref, signal: SignalKey, at: int, currency: str, components: List[int], amount: int }
  type Snapshot = { scope: str, issued: int, snapshot: str, model: str,
    scenario: str, seed: int, horizonStart: int, horizonEnd: int, evidence: Set[Evidence], allocations: List[Allocation],
    costs: List[Cost], claim: str }
  type State = { evidence: Set[Evidence], allocations: List[Allocation], costs: List[Cost],
    history: List[Snapshot], operation: int, violations: Set[str] }

  pure val issueAt = 10
  pure val tenantScope = "business-a"
  pure val signal = { measure: "physicalQuantity", family: "precious-metal", subject: "shipment-1", material: "silver", grade: "fine-999",
    form: "bar", unit: "fine-troy-ounce", currency: "USD", location: "London",
    instrument: "physical", maturity: 20 }
  pure def evidence(id: int, origin: str): Evidence =
    { ref: { source: id, revision: 1 }, key: signal, scope: tenantScope,
      published: 8, received: 9, effectiveFrom: 0, effectiveUntil: 30, origin: origin, quantityKnown: true, quantity: 2, payload: "digest-v1" }
  pure val observed = evidence(1, "observed")
  pure val scheduled = evidence(2, "observed").with("effectiveFrom", 20)
  pure val costSignal = signal.with("measure", "moneyMinorUnits").with("unit", "minor-unit").with("form", "delivered-cost")
  pure val hypothetical = evidence(3, "hypothetical").with("key", costSignal).with("quantity", 1)
  pure val denied = evidence(4, "observed")
  pure val lateReceipt = evidence(5, "observed").with("received", 11)
  pure val latePublication = evidence(6, "observed").with("published", 11)
  pure val foreignScope = evidence(7, "observed").with("scope", "business-b")
  pure val revised = observed.with("ref", observed.ref.with("revision", 2))
  pure val unknownEvidence = evidence(8, "observed").with("quantityKnown", false).with("quantity", 0)
  pure val zeroEvidence = evidence(9, "observed").with("quantity", 0)
  pure def quoteEvidence(id: int, amount: int): Evidence =
    evidence(id, "observed").with("key", costSignal).with("quantity", amount)
  pure val allInEvidence = quoteEvidence(10, 3)
  pure val fuelEvidence = quoteEvidence(11, 1)
  pure val freightEvidence = quoteEvidence(12, 2)
  pure val insuranceEvidence = quoteEvidence(13, 1)
  pure val foreignCurrencyEvidence = quoteEvidence(14, 1).with("key", costSignal.with("currency", "EUR"))
  pure val sources = Set(observed, scheduled, hypothetical, denied, lateReceipt,
    latePublication, foreignScope, unknownEvidence, zeroEvidence, allInEvidence,
    fuelEvidence, freightEvidence, insuranceEvidence, foreignCurrencyEvidence)
  pure def request(e: Evidence): EvidenceRequest =
    { expectedRef: e.ref, expectedKey: e.key, actual: e }
  pure def canRead(r: Ref): bool = r.source != 4

  pure val resourceKey = { scope: tenantScope, constraint: 1, bucket: 20 }
  pure val resource = { key: resourceKey, source: observed.ref, signal: signal,
    known: true, capacity: 2 }
  pure val unknownResource = resource.with("key", resourceKey.with("constraint", 2))
    .with("known", false).with("capacity", 0).with("source", unknownEvidence.ref)
  pure val zeroResource = resource.with("key", resourceKey.with("constraint", 3))
    .with("capacity", 0).with("source", zeroEvidence.ref)
  pure val earlyResource = resource.with("key", resourceKey.with("constraint", 4).with("bucket", 19))
    .with("source", scheduled.ref)
  pure val outsideResource = resource.with("key", resourceKey.with("bucket", 23))
  pure val inventedResource = resource.with("key", resourceKey.with("constraint", 5)).with("capacity", 3)
  pure val moneyResource = resource.with("key", resourceKey.with("constraint", 6))
    .with("source", allInEvidence.ref).with("signal", costSignal).with("capacity", 3)
  pure val catalog = Set(resource, unknownResource, zeroResource, earlyResource, outsideResource, inventedResource, moneyResource)
  pure def allocation(mode: str, quantity: int): Allocation =
    { key: resourceKey, source: observed.ref, signal: signal, mode: mode, quantity: quantity }
  pure def used(x: State, k: ResourceKey): int =
    x.allocations.foldl(0, (total, a) => total + (if (a.key == k) a.quantity else 0))
  pure def usedByMode(x: State, k: ResourceKey, mode: str): int =
    x.allocations.foldl(0, (total, a) => total +
      (if (a.key == k and a.mode == mode) a.quantity else 0))
  pure def admittedRef(x: State, r: Ref): bool = x.evidence.exists(e => e.ref == r)

  pure def cost(e: Evidence, ids: List[int]): Cost =
    { source: e.ref, signal: e.key, at: 20, currency: e.key.currency,
      components: ids, amount: e.quantity }
  pure val allIn = cost(allInEvidence, List(0, 1))
  pure val fuel = cost(fuelEvidence, List(0))
  pure val freight = cost(freightEvidence, List(1))
  pure val insurance = cost(insuranceEvidence, List(2))
  pure val foreignCurrencyCost = cost(foreignCurrencyEvidence, List(0))
  pure val hypotheticalCost = cost(hypothetical, List(2))
  pure def componentSet(c: Cost): Set[int] = c.components.foldl(Set(), (ids, i) => ids.union(Set(i)))
  pure def covered(x: State): Set[int] =
    x.costs.foldl(Set(), (ids, c) => ids.union(componentSet(c)))
  pure def chargedSources(x: State): Set[Ref] =
    x.costs.foldl(Set(), (refs, c) => refs.union(Set(c.source)))
  pure def componentCount(x: State): int =
    x.costs.foldl(0, (total, c) => total + c.components.length())

  pure val initial = { evidence: Set(), allocations: List(), costs: List(), history: List(),
    operation: 17, violations: Set() }
  var s: State

  // Monitors record the actual admission preconditions and publication preservation.
  // They are never bypassed by a mutant; a rejected request remains a literal no-op.
  pure def note(x: State, good: bool, label: str): State =
    if (good) x else x.with("violations", x.violations.union(Set(label)))

  pure def admit(x: State, r: EvidenceRequest, omit: str): State = {
    val e = r.actual
    val bound = r.expectedRef == e.ref and r.expectedKey == e.key
    val resolved = sources.contains(e)
    val inScope = e.scope == tenantScope
    val permitted = canRead(e.ref)
    val published = e.published <= issueAt
    val received = e.received <= issueAt
    val unique = not(x.evidence.exists(old => old.ref == e.ref))
    if ((bound or omit == "binding") and (resolved or omit == "resolution") and
        (inScope or omit == "scope") and (permitted or omit == "authorization") and
        (published or omit == "publication") and (received or omit == "receipt") and
        unique and e.effectiveFrom < e.effectiveUntil and e.payload != "") {
      note(note(note(note(note(note(x, bound, "binding"), resolved, "resolution"),
        inScope, "scope"), permitted, "authorization"), published, "publication"),
        received, "receipt").with("evidence", x.evidence.union(Set(e)))
    } else x
  }

  pure def reserve(x: State, a: Allocation, omit: str): State = {
    val matches = catalog.filter(r => r.key == a.key)
    if (matches.size() == 1) {
      val r = matches.fold(resource, (unused, entry) => entry)
      val exact = a.source == r.source and a.signal == r.signal
      val measureOK = r.signal.measure == "physicalQuantity"
      val admitted = x.evidence.exists(e => e.ref == r.source and e.key == r.signal and
        e.quantityKnown == r.known and e.quantity == r.capacity)
      val effective = x.evidence.exists(e => e.ref == r.source and
        e.effectiveFrom <= a.key.bucket and a.key.bucket < e.effectiveUntil)
      val horizon = 19 <= a.key.bucket and a.key.bucket < 23
      val pooled = used(x, a.key) + a.quantity <= r.capacity
      val capacityGuard = if (omit == "modePool")
        usedByMode(x, a.key, a.mode) + a.quantity <= r.capacity else pooled
      val knownGuard = if (omit == "unknown") true else r.known
      val boundGuard = if (omit == "unknown" and not(r.known))
        used(x, a.key) + a.quantity <= 2 else capacityGuard
      if ((exact or omit == "resourceBinding") and (admitted or omit == "capacitySource") and
          (measureOK or omit == "capacityMeasure") and
          (effective or omit == "effective") and (horizon or omit == "horizon") and knownGuard and boundGuard and
          a.quantity > 0 and a.mode.in(Set("road", "air", "sea")))
        note(note(x, exact, "resourceBinding"), r.known, "known")
          .with("allocations", x.allocations.append(a))
      else x
    } else x
  }

  pure def charge(x: State, c: Cost, omit: str): State = {
    val currency = c.currency == "USD" and c.currency == c.signal.currency
    val moneyRole = c.signal.measure == "moneyMinorUnits" and c.signal.unit == "minor-unit"
    val source = x.evidence.exists(e => e.ref == c.source and e.key == c.signal and
      e.quantityKnown and e.quantity == c.amount and e.effectiveFrom <= c.at and c.at < e.effectiveUntil)
    val horizon = 19 <= c.at and c.at < 23
    val unique = c.components.length() == componentSet(c).size()
    val freshSource = not(chargedSources(x).contains(c.source))
    val disjoint = componentSet(c).intersect(covered(x)).size() == 0
    if ((currency or omit == "currency") and (source or omit == "costSource") and horizon and
        (moneyRole or omit == "costRole") and (freshSource or omit == "costReplay") and
        (unique or omit == "componentUnique") and
        (disjoint or omit == "overlap") and c.components.length() > 0 and c.amount >= 0 and
        // Finite-model envelope only; Lean admits arbitrary well-formed lists.
        x.costs.length() < 3)
      note(note(x, currency, "currency"), unique, "componentUnique")
        .with("costs", x.costs.append(c))
    else x
  }

  pure def snapshot(x: State, claim: str): Snapshot =
    { scope: tenantScope, issued: issueAt, snapshot: "source-v1", model: "model-v1",
      scenario: "scenario-v1", seed: 7, horizonStart: 19, horizonEnd: 23, evidence: x.evidence, allocations: x.allocations,
      costs: x.costs, claim: claim }
  pure def publish(x: State, claim: str, omit: str): State = {
    val observedClaim = claim != "observed"
    val originOK = x.evidence.forall(e => e.origin == "observed") or claim == "scenario"
    val timeKindOK = claim != "nowcast" // Fixed issueAt=10 and horizon=[19,23): forecast is future, nowcast is not current.
    if ((observedClaim or omit == "observedClaim") and (originOK or omit == "scenario") and (timeKindOK or omit == "timeKind") and
        claim.in(Set("observed", "nowcast", "forecast", "scenario")) and
        x.history.length() < 2 and x.evidence.size() > 0) {
      val frozen = snapshot(x, claim)
      val nextHistory = if (omit == "history" and x.history.length() > 0)
        List(frozen) else x.history.append(frozen)
      val preserved = x.history.indices().forall(i => nextHistory.nth(i) == x.history.nth(i))
      val after = x.with("history", nextHistory)
      note(note(note(after, observedClaim, "observedClaim"), originOK, "scenario"),
        preserved, "history")
    } else x
  }

  // This is an explicit reachable prelude of ordinary source admissions, not a trusted state.
  pure val preludeSources = List(observed, scheduled, unknownEvidence, zeroEvidence,
    allInEvidence, fuelEvidence, freightEvidence, insuranceEvidence, foreignCurrencyEvidence)
  pure val ready = preludeSources.foldl(initial, (x, e) => admit(x, request(e), ""))
  action emptyInit = s' = initial
  action init = s' = ready
  action admitEvidence(r: EvidenceRequest): bool = s' = admit(s, r, "")
  action allocate(a: Allocation): bool = s' = reserve(s, a, "")
  action addCost(c: Cost): bool = s' = charge(s, c, "")
  action issue(claim: str): bool = s' = publish(s, claim, "")

  pure val keyMismatch = request(observed).with("expectedKey", signal.with("unit", "kilogram"))
  pure val maturityMismatch = request(observed).with("expectedKey", signal.with("maturity", 21))
  pure val refMismatch = request(observed).with("expectedRef", observed.ref.with("revision", 2))
  pure val wrongUnit = allocation("air", 1).with("signal", signal.with("unit", "kilogram"))
  pure val wrongMaterial = allocation("air", 1).with("signal", signal.with("material", "gold"))
  pure val wrongRevision = allocation("sea", 1).with("source", observed.ref.with("revision", 2))
  pure val unknown = allocation("road", 1).with("key", unknownResource.key).with("source", unknownEvidence.ref)
  pure val zero = allocation("road", 1).with("key", zeroResource.key).with("source", zeroEvidence.ref)
  pure val early = allocation("road", 1).with("key", earlyResource.key).with("source", scheduled.ref)
  pure val outside = allocation("road", 1).with("key", outsideResource.key)
  pure val invented = allocation("road", 3).with("key", inventedResource.key)
  pure val moneyAllocation = allocation("road", 3).with("key", moneyResource.key)
    .with("source", allInEvidence.ref).with("signal", costSignal)
  pure val physicalCost = cost(observed, List(0))

  action step = any {
    admitEvidence(request(observed)), admitEvidence(request(scheduled)),
    admitEvidence(request(hypothetical)), admitEvidence(request(denied)),
    admitEvidence(request(lateReceipt)), admitEvidence(request(latePublication)),
    admitEvidence(request(foreignScope)), admitEvidence(request(revised)),
    admitEvidence(keyMismatch), admitEvidence(maturityMismatch), admitEvidence(refMismatch),
    allocate(allocation("road", 1)), allocate(allocation("air", 1)), allocate(allocation("sea", 1)),
    allocate(allocation("road", 2)), allocate(unknown), allocate(zero),
    allocate(wrongUnit), allocate(wrongMaterial), allocate(wrongRevision), allocate(early),
    allocate(outside), allocate(invented), allocate(moneyAllocation),
    allocate(allocation("road", 0)),
    addCost(allIn), addCost(fuel), addCost(freight), addCost(insurance),
    addCost(foreignCurrencyCost), addCost(hypotheticalCost),
    addCost(fuel.with("amount", 9)), addCost(fuel.with("at", 23)), addCost(physicalCost), addCost(fuel.with("components", List(0, 0))),
    addCost(fuel.with("components", List())),
    issue("observed"), issue("nowcast"), issue("forecast"), issue("scenario")
  }

  val evidenceBinding = not(s.violations.contains("binding")) and
    not(s.violations.contains("resolution"))
  val knowledgeCutoff = s.evidence.forall(e => e.published <= issueAt and e.received <= issueAt)
  val scopeIsolation = s.evidence.forall(e => e.scope == tenantScope)
  val readAuthority = s.evidence.forall(e => canRead(e.ref))
  val resourceBinding = not(s.violations.contains("resourceBinding")) and
    s.allocations.foldl(true, (good, a) => good and catalog.exists(r => r.key == a.key and r.source == a.source and
      r.signal == a.signal and r.signal.measure == "physicalQuantity" and s.evidence.exists(e => e.ref == r.source and e.key == r.signal and
        e.quantityKnown == r.known and e.quantity == r.capacity)))
  val effectiveCapacity = s.allocations.foldl(true, (good, a) => good and 19 <= a.key.bucket and a.key.bucket < 23 and
    s.evidence.exists(e => e.ref == a.source and e.effectiveFrom <= a.key.bucket and a.key.bucket < e.effectiveUntil))
  val costSourceBinding = s.costs.foldl(true, (good, c) => good and 19 <= c.at and c.at < 23 and
    s.evidence.exists(e => e.ref == c.source and e.key == c.signal and e.quantityKnown and
      e.quantity == c.amount and e.effectiveFrom <= c.at and c.at < e.effectiveUntil))
  val capacityConservation = catalog.forall(r => used(s, r.key) <= r.capacity) and
    s.allocations.foldl(true, (good, a) => good and a.quantity > 0)
  val unknownCapacity = s.allocations.foldl(true, (good, a) => good and catalog.exists(r => r.key == a.key and r.known))
  val costSourceUniqueness = s.costs.length() == chargedSources(s).size()
  val componentDisjointness = componentCount(s) == covered(s).size()
  val currencyIdentity = s.costs.foldl(true, (good, c) => good and c.currency == "USD" and c.currency == c.signal.currency)
  val monetaryCostRole = s.costs.foldl(true, (good, c) => good and
    c.signal.measure == "moneyMinorUnits" and c.signal.unit == "minor-unit")
  val claimClassification = s.history.foldl(true, (good, p) => good and p.claim != "observed" and
    (p.evidence.forall(e => e.origin == "observed") or p.claim == "scenario"))
  val horizonClassification = s.history.foldl(true, (good, p) => good and
    (p.claim != "nowcast" or (p.horizonStart <= p.issued and p.issued < p.horizonEnd)) and
    (p.claim != "forecast" or p.issued < p.horizonStart))
  val publicationImmutability = not(s.violations.contains("history"))
  val noOperationalEffects = s.operation == 17
  val planningSafety = evidenceBinding and knowledgeCutoff and scopeIsolation and readAuthority and
    resourceBinding and effectiveCapacity and costSourceBinding and monetaryCostRole and capacityConservation and unknownCapacity and costSourceUniqueness and componentDisjointness and
    currencyIdentity and claimClassification and horizonClassification and publicationImmutability and noOperationalEffects

  action lateKnowledge = any { step, s' = admit(s, request(lateReceipt), "receipt") }
  action futurePublication = any { step, s' = admit(s, request(latePublication), "publication") }
  action substitutedEvidence = any { step, s' = admit(s, request(hypothetical).with("expectedRef", observed.ref), "binding") }
  action unpinnedRevision = any { step, s' = admit(s, request(revised), "resolution") }
  action foreignEvidence = any { step, s' = admit(s, request(foreignScope), "scope") }
  action deniedRead = any { step, s' = admit(s, request(denied), "authorization") }
  action substitutedResource = any { step, s' = reserve(s, wrongUnit, "resourceBinding") }
  action inventedCapacity = any { step, s' = reserve(s, invented, "capacitySource") }
  action earlyCapacity = any { step, s' = reserve(s, early, "effective") }
  action outsideHorizon = any { step, s' = reserve(s, outside, "horizon") }
  action physicalAsMoney = any { step, s' = charge(s, physicalCost, "costRole") }
  action moneyAsCapacity = any { step, s' = reserve(s, moneyAllocation, "capacityMeasure") }
  action inventedCost = any { step, s' = charge(s, fuel.with("amount", 9), "costSource") }
  action assumedUnknown = any { step, s' = reserve(s, unknown, "unknown") }
  action splitModePool = any { step, s' = reserve(s, allocation("air", 1), "modePool") }
  action doubleCountCost = any { step, s' = charge(s, fuel, "overlap") }
  action replayedTotalCost = any { step, s' = charge(s, allIn.with("components", List(2)), "costReplay") }
  action repeatedComponent = any { step, s' = charge(s, fuel.with("components", List(0, 0)), "componentUnique") }
  action mixedCurrency = any { step, s' = charge(s, foreignCurrencyCost, "currency") }
  action downgradedScenario = any { step, s' = publish(s, "forecast", "scenario") }
  action derivedObservation = any { step, s' = publish(s, "observed", "observedClaim") }
  action rewrittenPublication = any { step, s' = publish(s, "scenario", "history") }
  action futureNowcast = any { step, s' = publish(s, "nowcast", "timeKind") }
  action operationalWrite = any { step, s' = s.with("operation", 18) }

  run knownFutureEvidenceTest = emptyInit.then(admitEvidence(request(scheduled)))
    .expect(s.evidence.contains(scheduled) and scheduled.effectiveFrom > issueAt and planningSafety)
  run availabilityAndBindingTest = emptyInit.then(admitEvidence(request(lateReceipt)))
    .then(admitEvidence(request(latePublication))).then(admitEvidence(refMismatch))
    .then(admitEvidence(keyMismatch)).then(admitEvidence(maturityMismatch))
    .then(admitEvidence(request(revised))).then(admitEvidence(request(denied)))
    .then(admitEvidence(request(foreignScope))).expect(s == initial and planningSafety)
  run multimodalSharedPoolTest = init.then(admitEvidence(request(observed)))
    .then(allocate(allocation("sea", 1))).then(allocate(allocation("air", 1)))
    .then(allocate(allocation("road", 1))).expect(s.allocations.length() == 2 and
      used(s, resourceKey) == 2 and planningSafety)
  run reverseModeOrderTest = init.then(admitEvidence(request(observed)))
    .then(allocate(allocation("air", 1))).then(allocate(allocation("sea", 1)))
    .then(allocate(allocation("road", 1))).expect(s.allocations.length() == 2 and planningSafety)
  run unknownZeroAndWrongUnitsTest = init.then(admitEvidence(request(observed)))
    .then(allocate(unknown)).then(allocate(zero)).then(allocate(wrongUnit))
    .then(allocate(wrongMaterial)).then(allocate(wrongRevision))
    .then(allocate(early)).then(allocate(outside)).then(allocate(invented))
    .then(allocate(allocation("road", 0))).expect(s.allocations.length() == 0 and planningSafety)
  run allInAndCurrencyTest = init.then(addCost(allIn)).then(addCost(fuel))
    .then(addCost(freight)).then(addCost(insurance))
    .then(addCost(fuel.with("currency", "EUR")))
    .expect(s.costs == List(allIn, insurance) and componentCount(s) == 3 and planningSafety)
  run totalCostReplayTest = init.then(addCost(allIn))
    .then(addCost(allIn.with("components", List(2))))
    .expect(s.costs == List(allIn) and planningSafety)
  run invalidCostComponentsTest = init.then(addCost(fuel.with("components", List(0, 0))))
    .then(addCost(fuel.with("components", List()))).then(addCost(fuel.with("amount", 9)))
    .then(addCost(fuel.with("at", 23))).expect(s == ready and planningSafety)
  run dimensionalRolesTest = init.then(addCost(physicalCost)).then(allocate(moneyAllocation))
    .expect(s == ready and planningSafety)
  run reachablePreludeTest = emptyInit.then(admitEvidence(request(observed)))
    .then(admitEvidence(request(scheduled))).then(admitEvidence(request(unknownEvidence)))
    .then(admitEvidence(request(zeroEvidence))).then(admitEvidence(request(allInEvidence)))
    .then(admitEvidence(request(fuelEvidence))).then(admitEvidence(request(freightEvidence)))
    .then(admitEvidence(request(insuranceEvidence))).then(admitEvidence(request(foreignCurrencyEvidence)))
    .expect(s == ready and s.evidence.size() == 9 and planningSafety)
  run scenarioClassificationTest = emptyInit.then(admitEvidence(request(hypothetical)))
    .then(issue("forecast")).then(issue("nowcast")).then(issue("observed"))
    .then(addCost(hypotheticalCost)).then(issue("scenario")).expect(s.history.length() == 1 and
      s.history.nth(0).claim == "scenario" and s.costs == List(hypotheticalCost) and planningSafety)
  run frozenPublicationTest = emptyInit.then(admitEvidence(request(observed))).then(issue("forecast"))
    .then(admitEvidence(request(hypothetical))).then(admitEvidence(request(allInEvidence))).then(addCost(allIn))
    .then(allocate(allocation("sea", 1))).then(issue("scenario"))
    .expect(s.history.length() == 2 and s.history.nth(0).evidence == Set(observed) and
      s.history.nth(0).allocations.length() == 0 and s.history.nth(0).costs.length() == 0 and
      s.history.nth(1).evidence.contains(hypothetical) and s.operation == 17 and planningSafety)
  run missingEvidenceTest = emptyInit.then(allocate(allocation("sea", 1))).then(issue("forecast"))
    .expect(s == initial and planningSafety)
}
