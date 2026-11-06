// Synthetic single-request/two-revision transition model; no commerce execution.
// One merchant plus a distinct servicing store; owner 2 is a foreign quote namespace.
module merchant_pilot {
  type Pilot = { now: int, duplicate: bool, sharing: bool, qualified: bool,
    requestEnd: int, revision: int, firstAt: int, secondAt: int,
    firstEnd: int, secondEnd: int, accepted: int, acceptedAt: int,
    acceptedOwner: int, paidAt: int, deliveredAt: int, refund: int,
    refundAt: int, closedAt: int, merchantKnown: bool, storeKnown: bool,
    platformKnown: bool, overheadKnown: bool, coverage: int }
  type Report = { accepted: bool, requests: int, denominator: int, matched: int,
    merchantKnown: bool, storeKnown: bool, platformKnown: bool,
    merchant: int, store: int, platform: int }
  var s: Pilot
  var report: Report
  var last: int

  pure def ended(endAt, at) = endAt >= 0 and at >= endAt
  pure def quoteAt(p, rev) = if (rev == 1) p.firstAt else p.secondAt
  pure def quoteEnd(p, rev) = if (rev == 1) p.firstEnd else p.secondEnd
  pure def live(p, rev, at) = p.qualified and rev > 0 and rev <= p.revision
    and quoteAt(p, rev) <= at and at < 12 and not(ended(quoteEnd(p, rev), at))
    and not(ended(p.requestEnd, at))
  pure def eligible(p) = p.qualified and not(p.duplicate)
    and not(p.requestEnd >= 0 and p.requestEnd < 7) and p.now >= 7
  pure def hasMatch(p) = Set(1, 2).exists(rev => rev <= p.revision
    and quoteAt(p, rev) <= 7 and live(p, rev, quoteAt(p, rev)))
  pure def netStore(p) = if (p.paidAt < 0) 0 else
    250 - (if (p.refund == 10000) 250 else if (p.refund == 1000) 50 else 0)
  pure def netPlatform(p) = if (p.paidAt < 0) 0 else
    600 - (if (p.refund == 10000) 600 else if (p.refund == 1000) 100 else 0)
  pure def merchantMargin(p) = (if (p.paidAt >= 0) 10000 else 0) - p.refund
    - netStore(p) - netPlatform(p) - 7000
  pure def storeMargin(p) = netStore(p) - 180
  pure def platformMargin(p) = netPlatform(p) - 200
  pure def projection(p: Pilot): Report = {
    accepted: p.coverage >= p.now,
    requests: if (p.qualified) 1 else 0,
    denominator: if (eligible(p)) 1 else 0,
    matched: if (eligible(p) and hasMatch(p)) 1 else 0,
    merchantKnown: p.overheadKnown and (p.accepted == 0 or (p.closedAt >= 0 and p.merchantKnown)),
    storeKnown: p.overheadKnown and (p.accepted == 0 or (p.closedAt >= 0 and p.storeKnown)),
    platformKnown: p.overheadKnown and (p.accepted == 0 or (p.closedAt >= 0 and p.platformKnown)),
    merchant: (if (p.accepted == 0) 0 else merchantMargin(p)) - 25,
    store: (if (p.accepted == 0) 0 else storeMargin(p)) - 10,
    platform: (if (p.accepted == 0) 0 else platformMargin(p)) - 100,
  }
  action update(candidate, event) = all { s' = candidate, report' = projection(candidate), last' = event }
  action init = {
    val first: Pilot = {now: 0, duplicate: false, sharing: true, qualified: false,
      requestEnd: -1, revision: 0, firstAt: -1, secondAt: -1,
      firstEnd: -1, secondEnd: -1, accepted: 0, acceptedAt: -1,
      acceptedOwner: 0, paidAt: -1, deliveredAt: -1, refund: 0,
      refundAt: -1, closedAt: -1, merchantKnown: false, storeKnown: false,
      platformKnown: false, overheadKnown: false, coverage: 10}
    update(first, 0)
  }
  action tick = all { s.now < 10, update({...s, now: s.now + 1}, 1) }
  action qualify = all {not(s.qualified) and not(s.duplicate) and s.sharing
    and s.now == 0, update({...s, qualified: true}, 2)}
  action duplicate = all {not(s.qualified), update({...s, duplicate: true}, 3)}
  action revoke = all { s.sharing and s.now < 10,
    update({...s, now: s.now + 1, sharing: false,
      requestEnd: if (s.qualified) s.now + 1 else -1}, 4) }
  action issue = all {s.qualified and s.sharing and s.revision == 0 and s.now < 10,
    update({...s, now: s.now + 1, revision: 1, firstAt: s.now + 1}, 5)}
  action revise = all {s.revision == 1 and live(s, 1, s.now) and s.now < 10,
    update({...s, now: s.now + 1, revision: 2, secondAt: s.now + 1,
      firstEnd: if (s.firstEnd < 0) s.now + 1 else s.firstEnd}, 6)}
  action withdraw = all {s.revision > 0 and s.now < 10,
    update({...s, now: s.now + 1,
      firstEnd: if (s.revision == 1 and s.firstEnd < 0) s.now + 1 else s.firstEnd,
      secondEnd: if (s.revision == 2 and s.secondEnd < 0) s.now + 1 else s.secondEnd}, 7)}
  action accept(rev, owner) = {
    val valid = s.accepted == 0 and owner == 1 and rev == s.revision and live(s, rev, s.now)
    update(if (valid) {...s, accepted: rev, acceptedAt: s.now, acceptedOwner: owner} else s,
      if (valid) 8 else 9)
  }
  action acceptAny = {nondet rev = Set(1, 2).oneOf(); nondet owner = Set(1, 2).oneOf(); accept(rev, owner)}
  action pay = all {s.accepted > 0 and s.paidAt < 0 and s.closedAt < 0,
    update({...s, paidAt: s.now}, 10)}
  action deliver = all {s.accepted > 0 and s.deliveredAt < 0 and s.closedAt < 0,
    update({...s, deliveredAt: s.now}, 11)}
  action refund(amount) = all {s.paidAt >= 0 and s.closedAt < 0 and amount > s.refund,
    update({...s, refund: amount, refundAt: s.now}, 12)}
  action refundAny = {nondet amount = Set(1000, 10000).oneOf(); refund(amount)}
  action observeCosts(role) = update(if (role == 0) {...s, merchantKnown: true}
    else if (role == 1) {...s, storeKnown: true}
    else if (role == 2) {...s, platformKnown: true}
    else {...s, overheadKnown: true}, 13)
  action costs = {nondet role = Set(0, 1, 2, 3).oneOf(); observeCosts(role)}
  action close = all {s.paidAt >= 0 and s.deliveredAt >= 0 and s.closedAt < 0,
    update({...s, closedAt: s.now}, 14)}
  action loseCoverage = update({...s, coverage: 0}, 15)
  action refreshCoverage = update({...s, coverage: 10}, 16)
  action idle = update(s, 17)
  action step = any {tick, qualify, duplicate, revoke, issue, revise, withdraw,
    acceptAny, pay, deliver, refundAny, costs, close, loseCoverage, refreshCoverage, idle}

  val historicalAcceptance = s.accepted == 0 or (s.acceptedOwner == 1
    and live(s, s.accepted, s.acceptedAt))
  val noDuplicateDemand = not(s.duplicate and s.qualified)
  val noFabricatedEvidence = (s.refund == 0 or s.paidAt >= 0)
    and (s.closedAt < 0 or (s.paidAt >= 0 and s.deliveredAt >= 0))
  val correctProjection = report == projection(s)
  val safety = historicalAcceptance and noDuplicateDemand and noFabricatedEvidence and correctProjection

  // Deliberate mutations: the same safety invariant MUST fail on a witness trace.
  action staleAcceptance = all {s.revision == 2 and s.accepted == 0,
    update({...s, accepted: 1, acceptedAt: s.now, acceptedOwner: 1}, 90)}
  action foreignAcceptance = all {s.revision > 0 and s.accepted == 0,
    update({...s, accepted: s.revision, acceptedAt: s.now, acceptedOwner: 2}, 91)}
  action unknownAsZero = all {s.accepted > 0 and s.closedAt >= 0 and not(s.merchantKnown),
    s' = s, report' = {...projection(s), merchantKnown: true, merchant: 0}, last' = 92}
  action staleSourceExport = all {s.coverage < s.now,
    s' = s, report' = {...projection(s), accepted: true}, last' = 93}
  action duplicateDenominator = all {s.duplicate,
    s' = s, report' = {...projection(s), requests: 1, denominator: 1}, last' = 94}
  action unsafeStaleStep = any {step, staleAcceptance}
  action unsafeForeignStep = any {step, foreignAcceptance}
  action unsafeUnknownStep = any {step, unknownAsZero}
  action unsafeCoverageStep = any {step, staleSourceExport}
  action unsafeDuplicateStep = any {step, duplicateDenominator}

  run oldRevisionRejectedTest = init.then(qualify).then(issue).then(revise)
    .then(accept(1, 1)).then(all {idle, assert(s.accepted == 0 and safety)})
  run foreignOwnerRejectedTest = init.then(qualify).then(issue).then(accept(1, 2))
    .then(all {idle, assert(s.accepted == 0 and safety)})
  run acceptBeforeWithdrawalTest = init.then(qualify).then(issue).then(accept(1, 1))
    .then(withdraw).then(all {idle, assert(s.accepted == 1 and safety)})
  run withdrawnBeforeAcceptanceTest = init.then(qualify).then(issue).then(withdraw)
    .then(accept(1, 1)).then(all {idle, assert(s.accepted == 0 and safety)})
  run incompleteObservationTest = init.then(qualify).then(issue)
    .then(all {idle, assert(report.denominator == 0 and safety)})
  run lostCoverageTest = init.then(tick).then(loseCoverage)
    .then(all {idle, assert(not(report.accepted) and safety)})
  run duplicateExcludedTest = init.then(duplicate)
    .then(all {idle, assert(report.requests == 0 and safety)})
  run fullRefundLossTest = init.then(qualify).then(issue).then(accept(1, 1))
    .then(pay).then(deliver).then(refund(10000)).then(observeCosts(0))
    .then(observeCosts(1)).then(observeCosts(2)).then(observeCosts(3)).then(close)
    .then(all {idle, assert(report.merchant == -7025 and report.store == -190
      and report.platform == -300 and report.merchantKnown and safety)})
  run unknownExpenseTest = init.then(qualify).then(issue).then(accept(1, 1))
    .then(pay).then(deliver).then(close)
    .then(all {idle, assert(not(report.merchantKnown) and safety)})

  run mutationStaleTest = init.then(qualify).then(issue).then(revise).then(staleAcceptance)
    .then(all {idle, assert(not(safety))})
  run mutationForeignTest = init.then(qualify).then(issue).then(foreignAcceptance)
    .then(all {idle, assert(not(safety))})
  run mutationUnknownTest = init.then(qualify).then(issue).then(accept(1, 1))
    .then(pay).then(deliver).then(close).then(unknownAsZero)
    .then(all {idle, assert(not(safety))})
  run mutationCoverageTest = init.then(tick).then(loseCoverage).then(staleSourceExport)
    .then(all {idle, assert(not(safety))})
  run mutationDuplicateTest = init.then(duplicate).then(duplicateDenominator)
    .then(all {idle, assert(not(safety))})

  run sevenDayBoundaryTest = init.then(qualify).then(issue).then(6.reps(_ => tick))
    .then(all {idle, assert(report.denominator == 1 and report.matched == 1 and safety)})
  run earlyWithdrawalCohortTest = init.then(qualify).then(issue).then(revoke).then(5.reps(_ => tick))
    .then(all {idle, assert(report.denominator == 0 and report.requests == 1 and safety)})
  run historicalQuoteMatchTest = init.then(qualify).then(issue).then(withdraw).then(5.reps(_ => tick))
    .then(all {idle, assert(report.denominator == 1 and report.matched == 1 and safety)})
}
