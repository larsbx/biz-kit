// Bounded E3 admission/commit model: exactly five assignment IDs, two Users,
// two tenants and four participants. 0/1 are concurrent profiles for User 0;
// 2 is a re-enrolled exclusive profile for User 0; 3 belongs to User 1;
// 4 is exclusive with the same tenant/participant as 0.
// Identities are trusted inputs; commits are atomic. This is not a refinement
// proof of Elixir/Ash/PostgreSQL, authorization, locks, fairness or liveness.
// The audits counter models lifecycle status-transition events after planning.
// It excludes Board.plan's separate assignment.planned event at version 0 and
// is not a count of all persisted AuditEvent rows.
module dispatch_e3 {
  pure val IDS = Set(0, 1, 2, 3, 4)
  pure def trusted(t) = {
    user: if (t == 3) 1 else 0,
    tenant: if (t == 1) 1 else 0,
    participant: if (t == 4) 0 else t,
    exclusive: t >= 2,
  }
  var status: int -> str
  var version: int -> int
  var audits: int -> int
  var identity: int -> { user: int, tenant: int, participant: int, exclusive: bool }
  var pending: Set[int]
  var expected: int -> int
  var staged: int -> str
  var stagedVersion: int -> int
  var refusals: int
  var rollbacks: int

  // k=0 is E3; k=1 omits mixed-mode protection; k=2 omits global identity scope.
  def conflict(k, i, j) = identity.get(i).user == identity.get(j).user and
    (if (k == 1) identity.get(i).exclusive and identity.get(j).exclusive
     else (identity.get(i).exclusive or identity.get(j).exclusive) and
       (k != 2 or (identity.get(i).tenant == identity.get(j).tenant and
         identity.get(i).participant == identity.get(j).participant)))
  def available(k, t) = IDS.forall(j => j == t or status.get(j) != "ACTIVE" or not(conflict(k, t, j)))
  def sourceAllows(t, target) =
    (target == "COMPLETED" and status.get(t) == "ACTIVE") or
    (target == "CANCELLED" and (status.get(t) == "ACTIVE" or status.get(t) == "PLANNED"))

  action init = all {
    status' = IDS.mapBy(_ => "ABSENT"), version' = IDS.mapBy(_ => 0),
    audits' = IDS.mapBy(_ => 0), identity' = IDS.mapBy(t => trusted(t)),
    pending' = Set(), expected' = IDS.mapBy(_ => 0),
    staged' = IDS.mapBy(_ => "NONE"), stagedVersion' = IDS.mapBy(_ => 0),
    refusals' = 0, rollbacks' = 0,
  }
  action holdRows = all { status' = status, version' = version, audits' = audits, identity' = identity }
  action holdTransactions = all { pending' = pending, expected' = expected,
    staged' = staged, stagedVersion' = stagedVersion }
  action tick = all { holdRows, holdTransactions, refusals' = refusals, rollbacks' = rollbacks }
  action refuse = all { holdRows, holdTransactions, refusals' = refusals + 1, rollbacks' = rollbacks }

  action plan(t) = all {
    status.get(t) == "ABSENT", status' = status.set(t, "PLANNED"),
    version' = version, audits' = audits, identity' = identity,
    holdTransactions, refusals' = refusals, rollbacks' = rollbacks,
  }
  action refusePlan(t, supplied) = all {
    status.get(t) != "ABSENT" or supplied != trusted(t), refuse,
  }
  action begin(t, k) = all {
    status.get(t) == "PLANNED", not(pending.contains(t)), available(k, t),
    pending' = pending.union(Set(t)), expected' = expected.set(t, version.get(t)),
    staged' = staged, stagedVersion' = stagedVersion,
    holdRows, refusals' = refusals, rollbacks' = rollbacks,
  }
  action staleBegin(t) = all {
    status.get(t) == "PLANNED", not(pending.contains(t)),
    pending' = pending.union(Set(t)), expected' = expected.set(t, version.get(t) + 1),
    staged' = staged, stagedVersion' = stagedVersion,
    holdRows, refusals' = refusals, rollbacks' = rollbacks,
  }
  action activate(t, k, recheck) = all {
    pending.contains(t), status.get(t) == "PLANNED", expected.get(t) == version.get(t),
    not(recheck) or available(k, t),
    status' = status.set(t, "ACTIVE"), version' = version.set(t, version.get(t) + 1),
    audits' = audits.set(t, audits.get(t) + 1), identity' = identity,
    pending' = pending.exclude(Set(t)), expected' = expected,
    staged' = staged, stagedVersion' = stagedVersion,
    refusals' = refusals, rollbacks' = rollbacks,
  }
  action rejectActivation(t) = all {
    pending.contains(t), status.get(t) != "PLANNED" or expected.get(t) != version.get(t) or not(available(0, t)),
    pending' = pending.exclude(Set(t)), expected' = expected,
    staged' = staged, stagedVersion' = stagedVersion,
    holdRows, refusals' = refusals + 1, rollbacks' = rollbacks,
  }
  action refuseNonplanned(t) = all { status.get(t) != "PLANNED", refuse }
  action refuseConflict(t) = all { status.get(t) == "PLANNED", not(available(0, t)), refuse }

  // Staging is private transaction state: the committed ACTIVE row still blocks.
  action stageFinish(t, target) = all {
    sourceAllows(t, target), staged.get(t) == "NONE",
    staged' = staged.set(t, target), stagedVersion' = stagedVersion.set(t, version.get(t)),
    pending' = pending, expected' = expected,
    holdRows, refusals' = refusals, rollbacks' = rollbacks,
  }
  action commitFinish(t) = all {
    sourceAllows(t, staged.get(t)), version.get(t) == stagedVersion.get(t),
    status' = status.set(t, staged.get(t)), version' = version.set(t, version.get(t) + 1),
    audits' = audits.set(t, audits.get(t) + 1), identity' = identity,
    staged' = staged.set(t, "NONE"), stagedVersion' = stagedVersion,
    pending' = pending, expected' = expected, refusals' = refusals, rollbacks' = rollbacks,
  }
  action rollbackFinish(t) = all {
    staged.get(t) != "NONE", staged' = staged.set(t, "NONE"), stagedVersion' = stagedVersion,
    pending' = pending, expected' = expected,
    holdRows, refusals' = refusals, rollbacks' = rollbacks + 1,
  }
  action refuseSnapshot(t, supplied) = all {
    status.get(t) != "ABSENT", supplied != trusted(t), refuse,
  }
  pure def forged(t) = { user: 1 - trusted(t).user, tenant: trusted(t).tenant,
    participant: trusted(t).participant, exclusive: not(trusted(t).exclusive) }

  action step = {
    nondet t = IDS.oneOf()
    any { plan(t), refusePlan(t, forged(t)), begin(t, 0), staleBegin(t), activate(t, 0, true),
      rejectActivation(t), refuseNonplanned(t), refuseConflict(t), stageFinish(t, "COMPLETED"),
      stageFinish(t, "CANCELLED"), commitFinish(t), rollbackFinish(t), refuseSnapshot(t, forged(t)), tick }
  }
  val globalSafety = IDS.forall(i => IDS.forall(j => i == j or
    status.get(i) != "ACTIVE" or status.get(j) != "ACTIVE" or not(conflict(0, i, j))))
  val immutableSnapshots = IDS.forall(t => identity.get(t) == trusted(t))
  val safety = globalSafety and immutableSnapshots and IDS.forall(t => audits.get(t) == version.get(t))

  // Deliberately unsafe controls. Every control has a deterministic witness below
  // as well as a seeded simulation that must find an invariant counterexample.
  action weakStep(k, recheck) = {
    nondet t = IDS.oneOf()
    any { plan(t), begin(t, k), activate(t, k, recheck), tick }
  }
  action xxOnlyStep = weakStep(1, true)
  action tenantOnlyStep = weakStep(2, true)
  action preflightOnlyStep = weakStep(0, false)
  action mutateSnapshot(t) = all {
    status.get(t) != "ABSENT", identity' = identity.set(t, forged(t)),
    status' = status, version' = version, audits' = audits,
    holdTransactions, refusals' = refusals, rollbacks' = rollbacks,
  }
  action mutableStep = { nondet t = IDS.oneOf() any { plan(t), mutateSnapshot(t), tick } }
  action releaseEarly(t) = all {
    status.get(t) == "ACTIVE", staged.get(t) == "NONE",
    status' = status.set(t, "CANCELLED"), version' = version, audits' = audits, identity' = identity,
    staged' = staged.set(t, "CANCELLED"), stagedVersion' = stagedVersion.set(t, version.get(t)),
    pending' = pending, expected' = expected, refusals' = refusals, rollbacks' = rollbacks,
  }
  action restoreEarly(t) = all {
    staged.get(t) == "CANCELLED", status.get(t) == "CANCELLED",
    status' = status.set(t, "ACTIVE"), version' = version, audits' = audits, identity' = identity,
    staged' = staged.set(t, "NONE"), stagedVersion' = stagedVersion,
    pending' = pending, expected' = expected, refusals' = refusals, rollbacks' = rollbacks + 1,
  }
  action earlyReleaseStep = { nondet t = IDS.oneOf()
    any { plan(t), begin(t, 0), activate(t, 0, true), releaseEarly(t), restoreEarly(t), tick } }

  run concurrentThenExclusiveTest = init.then(plan(0)).then(plan(1)).then(plan(2))
    .then(begin(2, 0)).then(begin(0, 0)).then(begin(1, 0))
    .then(activate(0, 0, true)).then(activate(1, 0, true)).then(rejectActivation(2))
    .then(all { tick, assert(safety and status.get(0) == "ACTIVE" and status.get(1) == "ACTIVE"
      and status.get(2) == "PLANNED" and audits.get(2) == 0 and refusals == 1) })
  run independentUsersTest = init.then(plan(2)).then(plan(3))
    .then(begin(2, 0)).then(begin(3, 0)).then(activate(2, 0, true)).then(activate(3, 0, true))
    .then(all { tick, assert(safety and status.get(2) == "ACTIVE" and status.get(3) == "ACTIVE") })
  run crossTenantMixedTest = init.then(plan(1)).then(plan(2))
    .then(begin(1, 0)).then(begin(2, 0)).then(activate(1, 0, true)).then(rejectActivation(2))
    .then(all { tick, assert(safety and status.get(2) == "PLANNED" and refusals == 1) })
  run reenrolledUserTest = init.then(plan(0)).then(plan(2))
    .then(begin(0, 0)).then(begin(2, 0)).then(activate(2, 0, true)).then(rejectActivation(0))
    .then(all { tick, assert(safety and status.get(0) == "PLANNED" and refusals == 1) })
  run stagedCompletionTest = init.then(plan(2)).then(plan(1)).then(begin(2, 0)).then(activate(2, 0, true))
    .then(stageFinish(2, "COMPLETED")).then(refuseConflict(1))
    .then(all { tick, assert(status.get(2) == "ACTIVE" and version.get(2) == 1) })
    .then(commitFinish(2)).then(begin(1, 0)).then(activate(1, 0, true))
    .then(all { tick, assert(safety and status.get(2) == "COMPLETED" and status.get(1) == "ACTIVE") })
  run stagedCancellationRollbackTest = init.then(plan(2)).then(plan(0)).then(begin(2, 0)).then(activate(2, 0, true))
    .then(stageFinish(2, "CANCELLED")).then(refuseConflict(0)).then(rollbackFinish(2)).then(refuseConflict(0))
    .then(all { tick, assert(safety and status.get(2) == "ACTIVE" and version.get(2) == 1
      and audits.get(2) == 1 and rollbacks == 1 and refusals == 2) })
  run committedCancellationTest = init.then(plan(2)).then(plan(0)).then(begin(2, 0)).then(activate(2, 0, true))
    .then(stageFinish(2, "CANCELLED")).then(commitFinish(2)).then(begin(0, 0)).then(activate(0, 0, true))
    .then(all { tick, assert(safety and status.get(2) == "CANCELLED" and status.get(0) == "ACTIVE") })
  run plannedCancellationTest = init.then(plan(0)).then(begin(0, 0)).then(stageFinish(0, "CANCELLED"))
    .then(commitFinish(0)).then(rejectActivation(0)).then(refuseNonplanned(0))
    .then(all { tick, assert(safety and status.get(0) == "CANCELLED" and audits.get(0) == 1 and refusals == 2) })
  run staleVersionTest = init.then(plan(0)).then(staleBegin(0)).then(rejectActivation(0))
    .then(all { tick, assert(safety and version.get(0) == 0 and refusals == 1) })
  run absentActivationTest = init.then(refuseNonplanned(0))
    .then(all { tick, assert(safety and status.get(0) == "ABSENT" and audits.get(0) == 0 and refusals == 1) })
  run immutableSnapshotTest = init.then(refusePlan(0, forged(0))).then(plan(0))
    .then(refuseSnapshot(0, forged(0))).then(refusePlan(0, trusted(0)))
    .then(all { tick, assert(safety and identity.get(0) == trusted(0) and version.get(0) == 0 and refusals == 3) })
  run mixedModeCounterexampleTest = init.then(plan(0)).then(plan(4)).then(begin(0, 1)).then(begin(4, 1))
    .then(activate(0, 1, true)).then(activate(4, 1, true)).then(all { tick, assert(not(globalSafety)) })
  run tenantScopeCounterexampleTest = init.then(plan(1)).then(plan(2)).then(begin(1, 2)).then(begin(2, 2))
    .then(activate(1, 2, true)).then(activate(2, 2, true)).then(all { tick, assert(not(globalSafety)) })
  run preflightCounterexampleTest = init.then(plan(0)).then(plan(4)).then(begin(0, 0)).then(begin(4, 0))
    .then(activate(0, 0, false)).then(activate(4, 0, false)).then(all { tick, assert(not(globalSafety)) })
  run mutationCounterexampleTest = init.then(plan(0)).then(mutateSnapshot(0))
    .then(all { tick, assert(not(immutableSnapshots)) })
  run earlyReleaseCounterexampleTest = init.then(plan(2)).then(plan(0)).then(begin(2, 0)).then(activate(2, 0, true))
    .then(releaseEarly(2)).then(begin(0, 0)).then(activate(0, 0, true)).then(restoreEarly(2))
    .then(all { tick, assert(not(globalSafety)) })
}
