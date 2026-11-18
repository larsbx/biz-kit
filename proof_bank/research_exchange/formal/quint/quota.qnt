// Research Exchange reservation kernel. Finite balance: 3 units.
module quota {
  type State = { phase: str, available: int, held: int, spent: int }
  var s: State

  pure val initial = { phase: "idle", available: 3, held: 0, spent: 0 }
  pure def reserve(x: State, cap: int): State =
    if (x.phase == "idle" and cap >= 0 and cap <= x.available)
      x.with("phase", "reserved").with("available", x.available - cap).with("held", x.held + cap)
    else x
  pure def start(x: State): State =
    if (x.phase == "reserved") x.with("phase", "running") else x
  pure def cancel(x: State): State =
    if (x.phase == "reserved") x.with("phase", "stopped")
    else if (x.phase == "running") x.with("phase", "cancelling")
    else x
  pure def stop(x: State, trusted: bool): State =
    if (trusted and (x.phase == "running" or x.phase == "cancelling"))
      x.with("phase", "stopped")
    else x
  pure def settle(x: State, cost: int): State =
    if (x.phase == "stopped" and cost >= 0 and cost <= x.held)
      x.with("phase", "settled").with("available", x.available + x.held - cost).with("held", 0).with("spent", x.spent + cost)
    else x
  pure def release(x: State): State = settle(x, 0)

  // Negative control: cancellation refunds a process that has not stopped.
  pure def unsafeCancel(x: State): State =
    if (x.phase == "running")
      x.with("phase", "cancelling").with("available", x.available + x.held).with("held", 0)
    else cancel(x)

  // Transition observer records obligations, not implementation authority.
  var noEarlyRefund: bool
  action apply(after: State): bool = all {
    noEarlyRefund' = (noEarlyRefund and
      (if (s.phase == "running" or s.phase == "cancelling")
         after.available == s.available and after.held == s.held and after.spent == s.spent
       else true)),
    s' = after,
  }
  action init = all { s' = initial, noEarlyRefund' = true }
  action reserveStep = { nondet cap = 0.to(4).oneOf(); apply(reserve(s, cap)) }
  action startStep = apply(start(s))
  action cancelRequested = apply(cancel(s))
  action confirmedStopped = { nondet trusted = Set(false, true).oneOf(); apply(stop(s, trusted)) }
  action settleStep = { nondet cost = 0.to(4).oneOf(); apply(settle(s, cost)) }
  action releaseStep = apply(release(s))
  action step = any { reserveStep, startStep, cancelRequested, confirmedStopped, settleStep, releaseStep }
  action earlyRefundStep = any { reserveStep, startStep, apply(unsafeCancel(s)), confirmedStopped, settleStep, releaseStep }

  val conservation = s.available + s.held + s.spent == 3
  val nonnegative = s.available >= 0 and s.held >= 0 and s.spent >= 0
  val settledEmpty = if (s.phase == "settled") s.held == 0 else true
  val safety = conservation and nonnegative and settledEmpty and noEarlyRefund

  run normalSettlementTest = init
    .then(apply(reserve(s, 3))).then(startStep).then(apply(stop(s, true)))
    .then(apply(settle(s, 2))).expect(s == { phase: "settled", available: 1, held: 0, spent: 2 })
  run cancellationRetainsUntilStopTest = init
    .then(apply(reserve(s, 2))).then(startStep).then(cancelRequested)
    .expect(s.phase == "cancelling" and s.available == 1 and s.held == 2)
    .then(apply(settle(s, 0))).expect(s.phase == "cancelling" and s.held == 2)
    .then(apply(stop(s, false))).expect(s.phase == "cancelling" and s.held == 2)
    .then(apply(stop(s, true))).then(releaseStep)
    .expect(s.phase == "settled" and s.available == 3 and s.held == 0 and safety)
  run retriesAndBoundsTest = init
    .then(apply(reserve(s, 4))).expect(s == initial)
    .then(apply(reserve(s, 2))).then(apply(reserve(s, 2)))
    .expect(s.available == 1 and s.held == 2)
    .then(cancelRequested).then(apply(settle(s, 3))).expect(s.held == 2)
    .then(apply(settle(s, 1))).then(apply(settle(s, 1))).then(releaseStep)
    .expect(s == { phase: "settled", available: 2, held: 0, spent: 1 } and safety)
}
