// One accepted reservation over two reciprocal, equal-valued sources.
// Evidence is abstracted to authenticated scope, epoch, validity and consent.
module commercial_decision {
  type World = { sources: Set[int], owner: int, epoch: int, now: int, version: int }
  type Approval = { sources: Set[int], epoch: int, expiry: int, independent: bool }
  type Receipt = { world: World, approval: Approval }
  var world: World
  var prepared: World
  var approval: Approval
  var receipts: Set[Receipt]

  pure def eligible(w: World, a: Approval): bool =
    w.sources == Set(1, 2) and a.sources == w.sources and w.owner == 1
    and w.epoch == a.epoch and w.now < a.expiry and a.independent

  action init = all {
    world' = { sources: Set(1, 2), owner: 1, epoch: 1, now: 0, version: 1 },
    prepared' = { sources: Set(1, 2), owner: 1, epoch: 1, now: 0, version: 1 },
    approval' = { sources: Set(1, 2), epoch: 1, expiry: 2, independent: true },
    receipts' = Set(),
  }

  action change(w: World): bool = all {
    world' = w, prepared' = prepared, approval' = approval, receipts' = receipts,
  }

  action collect(a: Approval): bool = all {
    world' = world, prepared' = world, approval' = a, receipts' = receipts,
  }

  action commit = all {
    world' = world, prepared' = prepared, approval' = approval,
    receipts' = if (prepared == world and eligible(world, approval))
      receipts.union(Set({ world: world, approval: approval }))
      else receipts,
  }

  action interrupt = collect({ ...approval, independent: false })
  action revoke = change({ ...world, epoch: 2, version: 2 })
  action expire = change({ ...world, now: 2 })
  action compete = change({ ...world, owner: 2, version: 2 })
  action substitute = collect({ ...approval, sources: Set(1, 3) })
  action advance = change({ ...world, version: 2 })
  action step = any {
    commit, interrupt, revoke, expire, compete, substitute, advance, collect(approval),
  }

  val safety = receipts.forall(r => eligible(r.world, r.approval))
  run positiveRetryTest = init.then(commit).then(commit)
    .expect(receipts.size() == 1 and safety)
  run staleSnapshotTest = init.then(advance).then(commit).expect(receipts.size() == 0)
  run revokedGrantTest = init.then(revoke).then(collect(approval)).then(commit)
    .expect(receipts.size() == 0)
  run expiredApprovalTest = init.then(expire).then(collect(approval)).then(commit)
    .expect(receipts.size() == 0)
  run competingReservationTest = init.then(compete).then(collect(approval)).then(commit)
    .expect(receipts.size() == 0)
  run substitutedSourceTest = init.then(substitute).then(commit).expect(receipts.size() == 0)
  run interruptedPreparationTest = init.then(interrupt).then(commit).expect(receipts.size() == 0)
  run replayIsHistoricalTest = init.then(commit).then(revoke).then(commit)
    .expect(receipts.size() == 1 and safety)
}
