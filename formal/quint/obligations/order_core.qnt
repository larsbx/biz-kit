// order_core: "Authorization precedes state inspection, and no lifecycle state
// asserts payment or settlement."
//
// Models OrderCore.Lifecycle.apply/4 (apps/order_core/lib/order_core/
// lifecycle.ex): authorized?/3 (the actor's role is in the action's roles and
// the action is in allowed_actions) and scoped?/2 run first, and anything else
// returns a uniform :forbidden. Only then does apply_authorized/4 read the
// version, the transition table and the idempotency record. The state space is
// @core_states plus workflow stages, with no payment or settlement state.
// Abstracted: one order, pickup fulfillment, actions accept/complete/cancel,
// and responses as the information they reveal. GUARDED switches off the
// authorization-first check.
module order_core_spec {
  const GUARDED: bool

  pure val STATES = Set("placed", "accepted", "completed", "cancelled")
  pure val PAYMENT = Set("paid", "settled", "captured", "refunded")
  pure val ROLES = Map("accept" -> Set("admin", "staff"), "complete" -> Set("admin", "staff", "system"),
                       "cancel" -> Set("admin", "staff"))
  pure val TARGET = Map("accept" -> "accepted", "complete" -> "completed", "cancel" -> "cancelled")
  pure def legal(src: str, dst: str): bool =
    (src == "placed" and (dst == "accepted" or dst == "cancelled"))
    or (src == "accepted" and (dst == "completed" or dst == "cancelled"))

  var state: str
  var version: int
  // responses: (authorized, revealsState)
  var responses: List[(bool, bool)]

  action init = all { state' = "placed", version' = 0, responses' = [] }

  action command(actor: str, allowed: bool, act: str, expected: int): bool = {
    val authorized = ROLES.get(act).contains(actor) and allowed
    if (GUARDED and not(authorized))
      all { responses' = responses.append((false, false)), state' = state, version' = version }
    else if (expected == version and legal(state, TARGET.get(act)))
      all { responses' = responses.append((authorized, true)),
            state' = TARGET.get(act), version' = version + 1 }
    else
      // :stale_order_version or :invalid_transition reveal version and state.
      all { responses' = responses.append((authorized, true)), state' = state, version' = version }
  }

  action step = nondet actor = Set("admin", "staff", "system", "customer").oneOf()
    nondet allowed = Set(true, false).oneOf()
    nondet act = Set("accept", "complete", "cancel").oneOf()
    nondet expected = 0.to(2).oneOf()
    command(actor, allowed, act, expected)

  val obligation = all {
    responses.indices().forall(i => responses[i]._2 implies responses[i]._1),
    STATES.contains(state), not(PAYMENT.contains(state)),
  }

  // An authorized command completed the order.
  val obligationWitness = state != "completed"
}

module order_core {
  import order_core_spec(GUARDED = true).*
}

module order_core_control {
  import order_core_spec(GUARDED = false).*
}
