module admission {
  // Finite admission/queue abstraction. No claim about SQL or HTTP refinement.
  var active: bool
  var grant: int
  var version: int
  var first: bool
  var second: bool
  var queued: bool
  var qgrant: int
  var qversion: int
  var qid: int
  var sessionLive: bool
  var before: int
  var permitted: bool

  action init = all {
    active' = true, grant' = 1, version' = 0,
    first' = false, second' = false, queued' = false,
    qgrant' = 0, qversion' = 0, qid' = 0,
    sessionLive' = true, before' = 0, permitted' = false,
  }
  action queue(id: int): bool = all {
    not(queued),
    queued' = true, qgrant' = grant, qversion' = version, qid' = id,
    active' = active, grant' = grant, version' = version,
    first' = first, second' = second, sessionLive' = sessionLive,
    before' = version, permitted' = false,
  }
  action revoke = all {
    active' = false, grant' = grant,
    version' = version, first' = first, second' = second,
    queued' = queued, qgrant' = qgrant, qversion' = qversion, qid' = qid,
    sessionLive' = sessionLive, before' = version, permitted' = false,
  }
  action renew = all {
    grant < 3,
    active' = true, grant' = grant + 1,
    version' = version, first' = first, second' = second,
    queued' = queued, qgrant' = qgrant, qversion' = qversion, qid' = qid,
    sessionLive' = sessionLive, before' = version, permitted' = false,
  }
  action expire = all {
    sessionLive' = false,
    active' = active, grant' = grant, version' = version,
    first' = first, second' = second, queued' = queued,
    qgrant' = qgrant, qversion' = qversion, qid' = qid,
    before' = version, permitted' = false,
  }
  action process = {
    val seen = if (qid == 0) first else second
    val allowed = active and sessionLive and qgrant == grant
    val commit = allowed and not(seen) and qversion == version
    all {
      queued, queued' = false,
      version' = if (commit) version + 1 else version,
      first' = (first or (commit and qid == 0)),
      second' = (second or (commit and qid == 1)),
      active' = active, grant' = grant, sessionLive' = sessionLive,
      qgrant' = qgrant, qversion' = qversion, qid' = qid,
      before' = version, permitted' = allowed,
    }
  }
  // Recovery does not apply current expiry to an already-admitted prefix.
  action restart = all {
    active' = active, grant' = grant, version' = version,
    first' = first, second' = second, queued' = queued,
    qgrant' = qgrant, qversion' = qversion, qid' = qid,
    sessionLive' = sessionLive, before' = version, permitted' = false,
  }
  action step = any { queue(0), queue(1), process, revoke, renew, expire, restart }
  val invariant = all {
    version == (if (first) 1 else 0) + (if (second) 1 else 0),
    version >= before,
    not(permitted) implies version == before,
  }
  run revokedQueueTest = init.then(queue(0)).then(revoke).then(process)
    .expect(all { invariant, version == 0 })
  run replacedGrantTest = init.then(queue(0)).then(renew).then(process)
    .expect(all { invariant, version == 0 })
  run expiredSessionTest = init.then(queue(0)).then(expire).then(process)
    .expect(all { invariant, version == 0 })
  run retryTest = init.then(queue(0)).then(process).then(queue(0)).then(process)
    .expect(all { invariant, version == 1 })
  run historicalReplayTest = init.then(queue(0)).then(process).then(revoke).then(expire).then(restart)
    .expect(all { invariant, version == 1 })
}
