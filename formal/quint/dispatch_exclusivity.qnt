// Two preallocated trips. Immutable identities, one account, three scenarios:
// 0 same exclusive participant; 1 mixed profiles; 2 different tenants/participants;
// 3 two concurrent profiles.
// policy 1=E1, 2=E2, 3=E3. Atomic commits are a specification assumption.
module dispatch_exclusivity {
  pure val IDS = Set(0, 1)
  var scenario: int
  var policy: int
  var status: int -> str
  var version: int -> int
  var audits: int -> int
  var pending: Set[int]
  var snapshot: int -> int
  var refusals: int
  var rollbacks: int

  def tenant(i) = if (scenario == 2) i else 0
  def participant(i) = if (scenario == 2) i else 0
  def exclusive(i) = not(scenario == 3 or (scenario == 1 and i == 1))
  def conflict(k, i, j) =
    if (k == 1) tenant(i) == tenant(j) and participant(i) == participant(j)
      and exclusive(i) and exclusive(j)
    else if (k == 2) tenant(i) == tenant(j) and participant(i) == participant(j)
      and (exclusive(i) or exclusive(j))
    else exclusive(i) or exclusive(j) // user IDs are equal in every scenario
  def available(k, t) = IDS.forall(j =>
    j == t or status.get(j) != "ACTIVE" or not(conflict(k, t, j)))
  def invariant(k) = IDS.forall(i => IDS.forall(j =>
    i == j or status.get(i) != "ACTIVE" or status.get(j) != "ACTIVE"
      or not(conflict(k, i, j))))

  action initCase(sc, p) = all {
    scenario' = sc, policy' = p,
    status' = IDS.mapBy(_ => "PLANNED"), version' = IDS.mapBy(_ => 0),
    audits' = IDS.mapBy(_ => 0), pending' = Set(), snapshot' = IDS.mapBy(_ => 0),
    refusals' = 0, rollbacks' = 0,
  }
  action init = {
    nondet sc = Set(0, 1, 2, 3).oneOf()
    nondet p = Set(1, 2, 3).oneOf()
    initCase(sc, p)
  }

  action begin(t, k) = all {
    status.get(t) == "PLANNED", not(pending.contains(t)), available(k, t),
    pending' = pending.union(Set(t)), snapshot' = snapshot.set(t, version.get(t)),
    status' = status, version' = version, audits' = audits,
    scenario' = scenario, policy' = policy, refusals' = refusals, rollbacks' = rollbacks,
  }

  action activate(t, k, recheck) = all {
    pending.contains(t), status.get(t) == "PLANNED", snapshot.get(t) == version.get(t),
    not(recheck) or available(k, t),
    status' = status.set(t, "ACTIVE"), version' = version.set(t, version.get(t) + 1),
    audits' = audits.set(t, audits.get(t) + 1), pending' = pending.exclude(Set(t)),
    snapshot' = snapshot, scenario' = scenario, policy' = policy,
    refusals' = refusals, rollbacks' = rollbacks,
  }

  action finish(t, target) = all {
    if (target == "COMPLETED") status.get(t) == "ACTIVE"
      else status.get(t) == "ACTIVE" or status.get(t) == "PLANNED",
    status' = status.set(t, target), version' = version.set(t, version.get(t) + 1),
    audits' = audits.set(t, audits.get(t) + 1), pending' = pending,
    snapshot' = snapshot, scenario' = scenario, policy' = policy,
    refusals' = refusals, rollbacks' = rollbacks,
  }

  action abort(t, rejected) = all {
    pending.contains(t), pending' = pending.exclude(Set(t)),
    status' = status, version' = version, audits' = audits, snapshot' = snapshot,
    scenario' = scenario, policy' = policy,
    refusals' = refusals + (if (rejected) 1 else 0),
    rollbacks' = rollbacks + (if (rejected) 0 else 1),
  }
  action reject(t) = all {
    status.get(t) != "PLANNED" or snapshot.get(t) != version.get(t) or not(available(policy, t)),
    abort(t, true),
  }
  action tick = all {
    status' = status, version' = version, audits' = audits, pending' = pending,
    snapshot' = snapshot, scenario' = scenario, policy' = policy,
    refusals' = refusals, rollbacks' = rollbacks,
  }
  action step = {
    nondet t = IDS.oneOf()
    any { begin(t, policy), activate(t, policy, true), finish(t, "COMPLETED"),
      finish(t, "CANCELLED"), abort(t, false), reject(t), tick }
  }
  // Two deliberately weaker protocols: existing E1 guard; preflight-only guard.
  action tenantStep = {
    nondet t = IDS.oneOf()
    any { begin(t, 1), activate(t, 1, true), tick }
  }
  action snapshotStep = {
    nondet t = IDS.oneOf()
    any { begin(t, policy), activate(t, policy, false), tick }
  }
  val safety = invariant(policy) and IDS.forall(t => audits.get(t) == version.get(t))
  val globalSafety = invariant(3)
  val noActive = not(IDS.exists(t => status.get(t) == "ACTIVE"))
  val noCompleted = not(IDS.exists(t => status.get(t) == "COMPLETED"))
  val noCancelled = not(IDS.exists(t => status.get(t) == "CANCELLED"))
  val noRollback = rollbacks == 0
  val noStaleRefusal = not(refusals > 0 and IDS.exists(t => snapshot.get(t) != version.get(t)))
  val noConcurrentProfiles = not(scenario == 1 and policy == 1 and
    status.get(0) == "ACTIVE" and status.get(1) == "ACTIVE")

  run conflictingCommitTest = initCase(0, 3)
    .then(begin(0, 3)).then(begin(1, 3)).then(activate(0, 3, true))
    .then(reject(1)).then(all { tick, assert(safety and refusals == 1 and version.get(1) == 0) })
  run rollbackTest = initCase(0, 3).then(begin(0, 3)).then(abort(0, false))
    .then(all { tick, assert(status.get(0) == "PLANNED" and version.get(0) == 0 and audits.get(0) == 0) })
    .then(begin(1, 3)).then(activate(1, 3, true)).then(all { tick, assert(safety) })
  run completeReleaseTest = initCase(0, 3).then(begin(0, 3)).then(activate(0, 3, true))
    .then(finish(0, "COMPLETED")).then(begin(1, 3)).then(activate(1, 3, true))
    .then(all { tick, assert(safety and status.get(1) == "ACTIVE") })
  run cancelReleaseTest = initCase(0, 3).then(begin(0, 3)).then(activate(0, 3, true))
    .then(finish(0, "CANCELLED")).then(begin(1, 3)).then(activate(1, 3, true))
    .then(all { tick, assert(safety and status.get(1) == "ACTIVE") })
  run staleVersionTest = initCase(0, 3).then(begin(0, 3)).then(finish(0, "CANCELLED"))
    .then(reject(0)).then(all { tick, assert(safety and refusals == 1 and version.get(0) == 1) })
  run concurrentProfilesTest = initCase(3, 3)
    .then(begin(0, 3)).then(begin(1, 3)).then(activate(0, 3, true)).then(activate(1, 3, true))
    .then(all { tick, assert(safety and status.get(0) == "ACTIVE" and status.get(1) == "ACTIVE") })
  run mixedIndexCounterexampleTest = initCase(1, 1)
    .then(begin(0, 1)).then(begin(1, 1)).then(activate(0, 1, true)).then(activate(1, 1, true))
    .then(all { tick, assert(invariant(1) and not(invariant(2))) })
  run crossTenantCounterexampleTest = initCase(2, 1)
    .then(begin(0, 1)).then(begin(1, 1)).then(activate(0, 1, true)).then(activate(1, 1, true))
    .then(all { tick, assert(invariant(1) and not(globalSafety)) })
  run snapshotRaceCounterexampleTest = initCase(0, 3)
    .then(begin(0, 3)).then(begin(1, 3)).then(activate(0, 3, false)).then(activate(1, 3, false))
    .then(all { tick, assert(not(safety)) })
}
