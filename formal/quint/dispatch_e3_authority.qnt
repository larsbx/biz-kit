// Temporal authority around one blocked E3 activation (issue #296).
//
// Two exclusive assignments of one User always conflict. An activation is
// admitted (authority read after its locks), writes its uncommitted ACTIVE row
// (waiting while the other assignment's uncommitted row holds the index), and
// commits later. The clock may advance, and the session may end, anywhere.
//
// Authority has three parts with different physics:
//   validUntil  clock-bounded (grant/token lifetime): no lock stops the clock;
//   revoked     database-recorded: the admitted transaction's share lock makes
//               a revocation wait for its commit or rollback;
//   session     an external store: neither a clock read nor a row lock.
//
// The four step relations are the candidate policies. This file does not pick
// one. It records which invariants each satisfies and which it violates.
//   A  admission   no further check (the merged runtime);
//   B  bounded     commit only within BOUND ticks of admission;
//   R  recheck     application re-reads authority after the wait, then commits
//                  in a later step;
//   C  commit      authority is evaluated atomically with the commit.
// C is an idealization: no application can read a wall clock or another store
// in the same instant as a PostgreSQL commit. R is what an application-level
// revalidation achieves. Not a refinement of Elixir/Ash/PostgreSQL; no
// liveness, fairness or deadlock claim.
module dispatch_e3_authority {
  pure val IDS = Set(0, 1)
  pure val MAX_TIME = 4
  pure val BOUND = 1

  type State = {
    now: int,
    status: int -> str,
    phase: int -> str,
    validUntil: int -> int,
    revoked: int -> bool,
    session: int -> bool,
    admittedAt: int -> int,
    checkedAt: int -> int,
    committedAt: int -> int,
    lapsedAtCommit: int -> bool,
    revokedAtCommit: int -> bool,
    refusals: int,
  }
  var s: State

  pure def zero(v) = IDS.mapBy(_ => v)
  def other(t) = 1 - t
  def clockValid(t, at) = at < s.validUntil.get(t)
  def authority(t) = clockValid(t, s.now) and s.session.get(t) and not(s.revoked.get(t))
  def inFlight(t) = s.phase.get(t) == "HELD" or s.phase.get(t) == "CHECKED"
  def guard(t, p) =
    if (p == "B") s.now - s.admittedAt.get(t) <= BOUND
    else if (p == "R") s.phase.get(t) == "CHECKED"
    else if (p == "C") authority(t)
    else true

  action init = {
    nondet v0 = 1.to(MAX_TIME).oneOf()
    nondet v1 = 1.to(MAX_TIME).oneOf()
    s' = {
      now: 0, status: zero("PLANNED"), phase: zero("IDLE"),
      validUntil: Map(0 -> v0, 1 -> v1), revoked: zero(false), session: zero(true),
      admittedAt: zero(0), checkedAt: zero(0), committedAt: zero(0),
      lapsedAtCommit: zero(false), revokedAtCommit: zero(false), refusals: 0,
    }
  }
  action refused(t) = s' = { ...s, phase: s.phase.set(t, "IDLE"), refusals: s.refusals + 1 }

  action tick = all { s.now < MAX_TIME, s' = { ...s, now: s.now + 1 } }
  action endSession(t) = all { s.session.get(t), s' = { ...s, session: s.session.set(t, false) } }
  // locked = true is the real writer: FOR SHARE held from admission to commit.
  action revoke(t, locked) = all {
    not(s.revoked.get(t)), not(locked) or s.phase.get(t) == "IDLE",
    s' = { ...s, revoked: s.revoked.set(t, true) },
  }
  action admit(t) = all {
    s.phase.get(t) == "IDLE", s.status.get(t) == "PLANNED", authority(t),
    s' = { ...s, phase: s.phase.set(t, "ADMITTED"), admittedAt: s.admittedAt.set(t, s.now) },
  }
  action refuseAdmit(t) = all {
    s.phase.get(t) == "IDLE", s.status.get(t) == "PLANNED", not(authority(t)), refused(t),
  }
  // The index wait: disabled while the other assignment's row is uncommitted.
  action write(t) = all {
    s.phase.get(t) == "ADMITTED", not(inFlight(other(t))), s.status.get(other(t)) != "ACTIVE",
    s' = { ...s, phase: s.phase.set(t, "HELD") },
  }
  action refuseOccupied(t) = all {
    s.phase.get(t) == "ADMITTED", s.status.get(other(t)) == "ACTIVE", refused(t),
  }
  action recheck(t) = all {
    s.phase.get(t) == "HELD", authority(t),
    s' = { ...s, phase: s.phase.set(t, "CHECKED"), checkedAt: s.checkedAt.set(t, s.now) },
  }
  action commit(t, p) = all {
    inFlight(t), guard(t, p),
    s' = { ...s, status: s.status.set(t, "ACTIVE"), phase: s.phase.set(t, "IDLE"),
      committedAt: s.committedAt.set(t, s.now),
      lapsedAtCommit: s.lapsedAtCommit.set(t, not(clockValid(t, s.now) and s.session.get(t))),
      revokedAtCommit: s.revokedAtCommit.set(t, s.revoked.get(t)) },
  }
  action refuseCommit(t, p) = all {
    inFlight(t), if (p == "R") s.phase.get(t) == "HELD" and not(authority(t)) else not(guard(t, p)),
    refused(t),
  }
  action rollback(t) = all { s.phase.get(t) != "IDLE", s' = { ...s, phase: s.phase.set(t, "IDLE") } }

  action stepWith(p, locked) = {
    nondet t = IDS.oneOf()
    any { tick, endSession(t), revoke(t, locked), admit(t), refuseAdmit(t), write(t),
      refuseOccupied(t), all { p == "R", recheck(t) }, commit(t, p), refuseCommit(t, p), rollback(t) }
  }
  action step = stepWith("A", true)
  action boundedStep = stepWith("B", true)
  action recheckStep = stepWith("R", true)
  action commitStep = stepWith("C", true)
  // Control: a revocation that ignores the admitted transaction's share lock.
  action unlockedStep = stepWith("A", false)

  def active(t) = s.status.get(t) == "ACTIVE"
  val occupancy = not(active(0) and active(1))
  val admissionAuthority = IDS.forall(t => active(t) implies clockValid(t, s.admittedAt.get(t)))
  val revocationOrdered = IDS.forall(t => active(t) implies not(s.revokedAtCommit.get(t)))
  val commitAuthority = IDS.forall(t => active(t) implies not(s.lapsedAtCommit.get(t)))
  val boundedStaleness = IDS.forall(t => active(t) implies
    s.committedAt.get(t) - s.admittedAt.get(t) <= BOUND)
  val boundedClockLapse = IDS.forall(t => active(t) implies
    s.committedAt.get(t) < s.validUntil.get(t) + BOUND)
  val recheckAuthority = IDS.forall(t => active(t) implies clockValid(t, s.checkedAt.get(t)))
  // Held by every candidate with the real (locked) revocation.
  val baseline = occupancy and admissionAuthority and revocationOrdered
  // Non-vacuity: an activation that waited across a clock tick does commit.
  val neverWaitedCommit = IDS.forall(t => active(t) implies s.committedAt.get(t) == s.admittedAt.get(t))

  // Directed witnesses. 0 holds the index; 1 is admitted and waits behind it.
  pure val LIVE = { now: 0, status: zero("PLANNED"), phase: zero("IDLE"),
    validUntil: Map(0 -> MAX_TIME, 1 -> 1), revoked: zero(false), session: zero(true),
    admittedAt: zero(0), checkedAt: zero(0), committedAt: zero(0),
    lapsedAtCommit: zero(false), revokedAtCommit: zero(false), refusals: 0 }
  action blocked = (s' = LIVE).then(admit(0)).then(write(0)).then(admit(1))
  run indexWaitTest = blocked.then(write(1)).fail()
  run expiryAdmissionTest = blocked.then(tick).then(rollback(0)).then(write(1)).then(commit(1, "A"))
    .then(all { tick, assert(baseline and not(commitAuthority) and s.committedAt.get(1) == 1
      and s.admittedAt.get(1) == 0 and s.validUntil.get(1) == 1) })
  run expiryCommitTest = blocked.then(tick).then(rollback(0)).then(write(1)).then(refuseCommit(1, "C"))
    .then(all { tick, assert(commitAuthority and s.status.get(1) == "PLANNED" and s.refusals == 1) })
  run expiryCommitNotEnabledTest = blocked.then(tick).then(rollback(0)).then(write(1))
    .then(commit(1, "C")).fail()
  run logoutAdmissionTest = blocked.then(endSession(1)).then(rollback(0)).then(write(1))
    .then(commit(1, "A")).then(all { tick, assert(baseline and not(commitAuthority)
      and clockValid(1, s.committedAt.get(1))) })
  run logoutCommitTest = blocked.then(endSession(1)).then(rollback(0)).then(write(1))
    .then(refuseCommit(1, "C")).then(all { tick, assert(s.status.get(1) == "PLANNED") })
  run revocationWaitsTest = blocked.then(revoke(1, true)).fail()
  run revocationAfterCommitTest = blocked.then(rollback(0)).then(write(1)).then(commit(1, "C"))
    .then(revoke(1, true)).then(all { tick, assert(baseline and commitAuthority and s.revoked.get(1)) })
  run revocationBeforeAdmissionTest = (s' = LIVE).then(revoke(1, true)).then(refuseAdmit(1))
    .then(all { tick, assert(s.status.get(1) == "PLANNED" and s.refusals == 1) })
  run unlockedRevocationCounterexampleTest = blocked.then(revoke(1, false)).then(rollback(0))
    .then(write(1)).then(commit(1, "A")).then(all { tick, assert(not(revocationOrdered)) })
  run boundedWaitRefusedTest = blocked.then(tick).then(tick).then(rollback(0)).then(write(1))
    .then(refuseCommit(1, "B")).then(all { tick, assert(s.status.get(1) == "PLANNED") })
  run boundedLapseTest = blocked.then(tick).then(rollback(0)).then(write(1)).then(commit(1, "B"))
    .then(all { tick, assert(boundedStaleness and boundedClockLapse and not(commitAuthority)) })
  run recheckRefusedTest = blocked.then(tick).then(rollback(0)).then(write(1)).then(recheck(1)).fail()
  // The residual window: valid at the recheck, lapsed by the commit.
  run recheckWindowTest = (s' = { ...LIVE, validUntil: Map(0 -> MAX_TIME, 1 -> 2) })
    .then(admit(0)).then(write(0)).then(admit(1)).then(tick).then(rollback(0)).then(write(1))
    .then(recheck(1)).then(tick).then(commit(1, "R"))
    .then(all { tick, assert(recheckAuthority and not(commitAuthority)) })
  run occupancyStillRefusedTest = blocked.then(commit(0, "C")).then(refuseOccupied(1))
    .then(all { tick, assert(occupancy and s.status.get(1) == "PLANNED" and s.refusals == 1) })
}
