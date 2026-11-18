// One canonical Idempotency-Key in one tenant/role scope, within ONE retention epoch.
// An epoch starts with the first committed claim and ends when that claim expires
// (24 hours in the runtime). `mutations` counts only that epoch, not all history.
// Expiration/purge and claiming a new epoch are outside this model. A runtime
// restart here occurs while the same persisted claim remains unexpired.
// A retry is a replay ONLY when method, resource target, and canonical body
// all match the original claim; every different request is rejected.
// Storage durability and transaction coupling are runtime obligations.
module dispatch_idempotency {
  pure val METHODS = Set("POST", "PATCH")
  pure val TARGETS = Set("loadA", "loadB")
  var claimed: bool
  var savedMethod: str
  var savedTarget: str
  var savedBody: int
  var mutations: int
  var replays: int
  var conflicts: int
  var lastReplayTarget: str

  action init = all {
    claimed' = false,
    savedMethod' = "",
    savedTarget' = "",
    savedBody' = 0,
    mutations' = 0,
    replays' = 0,
    conflicts' = 0,
    lastReplayTarget' = "",
  }

  action firstMutation = {
    nondet method = METHODS.oneOf()
    nondet target = TARGETS.oneOf()
    nondet body = 1.to(2).oneOf()
    all {
      not(claimed),
      claimed' = true,
      savedMethod' = method,
      savedTarget' = target,
      savedBody' = body,
      mutations' = mutations + 1,
      replays' = replays,
      conflicts' = conflicts,
      lastReplayTarget' = lastReplayTarget,
    }
  }

  action sameRequestRetry = {
    nondet method = METHODS.oneOf()
    nondet target = TARGETS.oneOf()
    nondet body = 1.to(2).oneOf()
    all {
      claimed,
      method == savedMethod,
      target == savedTarget,
      body == savedBody,
      claimed' = claimed,
      savedMethod' = savedMethod,
      savedTarget' = savedTarget,
      savedBody' = savedBody,
      mutations' = mutations,
      replays' = replays + 1,
      conflicts' = conflicts,
      lastReplayTarget' = target,
    }
  }

  action differentRequestRejected = {
    nondet method = METHODS.oneOf()
    nondet target = TARGETS.oneOf()
    nondet body = 1.to(2).oneOf()
    all {
      claimed,
      method != savedMethod or target != savedTarget or body != savedBody,
      claimed' = claimed,
      savedMethod' = savedMethod,
      savedTarget' = savedTarget,
      savedBody' = savedBody,
      mutations' = mutations,
      replays' = replays,
      conflicts' = conflicts + 1,
      lastReplayTarget' = lastReplayTarget,
    }
  }

  action restart = all {
    claimed' = claimed,
    savedMethod' = savedMethod,
    savedTarget' = savedTarget,
    savedBody' = savedBody,
    mutations' = mutations,
    replays' = replays,
    conflicts' = conflicts,
    lastReplayTarget' = lastReplayTarget,
  }

  action step = any { firstMutation, sameRequestRetry, differentRequestRejected, restart }

  val safety =
    mutations <= 1 and
    (claimed implies mutations == 1) and
    (not(claimed) implies mutations == 0) and
    (replays > 0 implies (claimed and lastReplayTarget == savedTarget))

  val noReplayWitness = not(replays > 0)
  val noConflictWitness = not(conflicts > 0)
}
