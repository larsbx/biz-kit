// Immutable, verified, complete native-history snapshot. This is an admission
// target, not a signature/native-history verifier or an EventStore adapter.
// Scope = (home, destination, cluster, generation). All scopes deliberately
// share original operation anchors, so omitted namespace fields can collide.
module tb_outcome_admission {
  type Scope = (int, int, int, int)
  type Key = (Scope, int)
  pure val SCOPES = Set((0, 0, 0, 0), (1, 0, 0, 0), (0, 1, 0, 0),
    (0, 0, 1, 0), (0, 0, 0, 1))
  pure val POSITIONS = Set(1, 2)
  pure def anchor(n) = 100 + n
  pure val KEYS = tuples(SCOPES, Set(101, 102))
  pure def key(scope, n) = (scope, anchor(n))
  // These distinct finite tokens stand for exact authenticated outcome bytes.
  // Destination is deliberately excluded: the same source goes to both sinks.
  pure def expected(scope, n) =
    1000 * scope._1 + 100 * scope._3 + 10 * scope._4 + n

  var stored: Key -> int         // -1 means no accepted outcome
  var appends: Key -> int        // actual durable append count, not attempts
  var cursor: Scope -> int       // complete-group ordinal, NOT a native ID

  action init = all {
    stored' = KEYS.mapBy(_ => -1),
    appends' = KEYS.mapBy(_ => 0),
    cursor' = SCOPES.mapBy(_ => 0),
  }

  action admit(scope, n, body, verified) = {
    val k = key(scope, n)
    val fresh = verified and POSITIONS.contains(n)
      and body == expected(scope, n) and stored.get(k) == -1
    all {
      stored' = if (fresh) stored.set(k, body) else stored,
      appends' = if (fresh) appends.set(k, appends.get(k) + 1) else appends,
      cursor' = cursor,
    }
  }

  action checkpoint(scope) = {
    val nextPosition = cursor.get(scope) + 1
    all {
      cursor' = if (if (POSITIONS.contains(nextPosition))
        stored.get(key(scope, nextPosition)) == expected(scope, nextPosition)
        else false) cursor.set(scope, nextPosition) else cursor,
      stored' = stored,
      appends' = appends,
    }
  }

  action crash = all { stored' = stored, appends' = appends, cursor' = cursor }

  action deliver = {
    nondet scope = SCOPES.oneOf()
    nondet n = POSITIONS.oneOf()
    nondet good = Set(true, false).oneOf()
    nondet verified = Set(true, false).oneOf()
    admit(scope, n, if (good) expected(scope, n) else -2, verified)
  }

  action advance = { nondet scope = SCOPES.oneOf(); checkpoint(scope) }
  action step = any { deliver, advance, crash }

  val durableBinding = SCOPES.forall(scope => POSITIONS.forall(n => {
    val k = key(scope, n)
    (stored.get(k) == -1 and appends.get(k) == 0) or
      (stored.get(k) == expected(scope, n) and appends.get(k) == 1)
  }))
  val prefixSafe = SCOPES.forall(scope => cursor.get(scope) >= 0
    and cursor.get(scope) <= 2 and POSITIONS.forall(n =>
      (n <= cursor.get(scope)) implies
        stored.get(key(scope, n)) == expected(scope, n)))
  val safety = durableBinding and prefixSafe

  val noAppendBeforeCursor = not(stored.get(key((0, 0, 0, 0), 1)) == 1
    and cursor.get((0, 0, 0, 0)) == 0)
  val noOutOfOrder = not(stored.get(key((0, 0, 0, 0), 2)) == 2
    and stored.get(key((0, 0, 0, 0), 1)) == -1)
  val noIndependentSink = not(cursor.get((0, 0, 0, 0)) == 2
    and cursor.get((0, 1, 0, 0)) == 0)

  // Each mutation must produce an invariant violation after a safe prefix.
  action duplicateAppend = {
    nondet k = KEYS.oneOf()
    all { stored.get(k) != -1, appends' = appends.set(k, appends.get(k) + 1),
      stored' = stored, cursor' = cursor }
  }
  action changedBody = {
    nondet k = KEYS.oneOf()
    all { stored.get(k) != -1, stored' = stored.set(k, -2),
      appends' = appends, cursor' = cursor }
  }
  action cursorFirst = {
    nondet scope = SCOPES.oneOf()
    all { cursor.get(scope) < 2, cursor' = cursor.set(scope, cursor.get(scope) + 1),
      stored' = stored, appends' = appends }
  }
  action forgetBinding = {
    nondet k = KEYS.oneOf()
    all { stored.get(k) != -1, stored' = stored.set(k, -1),
      appends' = appends, cursor' = cursor }
  }
  action unsafeDuplicateStep = any { step, duplicateAppend }
  action unsafeBodyStep = any { step, changedBody }
  action unsafeCursorStep = any { step, cursorFirst }
  action unsafeForgetStep = any { step, forgetBinding }

  run lostReplyRetryTest = init
    .then(admit((0, 0, 0, 0), 1, 1, true))
    .then(crash)
    .then(admit((0, 0, 0, 0), 1, 1, true))
    .then(all { crash, assert(appends.get(key((0, 0, 0, 0), 1)) == 1) })
    .then(checkpoint((0, 0, 0, 0)))
    .then(all { crash, assert(cursor.get((0, 0, 0, 0)) == 1 and safety) })

  run changedBodyTest = init
    .then(admit((0, 0, 0, 0), 1, 1, true))
    .then(admit((0, 0, 0, 0), 1, -2, true))
    .then(all { crash, assert(stored.get(key((0, 0, 0, 0), 1)) == 1 and safety) })

  run unverifiedTest = init
    .then(admit((0, 0, 0, 0), 1, 1, false))
    .then(checkpoint((0, 0, 0, 0)))
    .then(all { crash, assert(cursor.get((0, 0, 0, 0)) == 0 and safety) })

  run outOfOrderTest = init
    .then(admit((0, 0, 0, 0), 2, 2, true))
    .then(checkpoint((0, 0, 0, 0)))
    .then(all { crash, assert(cursor.get((0, 0, 0, 0)) == 0 and safety) })

  run sameNumericAnchorScopesTest = init
    .then(admit((0, 0, 0, 0), 1, 1, true))
    .then(admit((1, 0, 0, 0), 1, 1001, true))
    .then(admit((0, 1, 0, 0), 1, 1, true))
    .then(admit((0, 0, 1, 0), 1, 101, true))
    .then(admit((0, 0, 0, 1), 1, 11, true))
    .then(all { crash, assert(SCOPES.forall(scope =>
      appends.get(key(scope, 1)) == 1 and stored.get(key(scope, 1)) == expected(scope, 1))
      and safety) })
}
