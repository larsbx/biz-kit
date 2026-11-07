// Obligation (fulfillment_core): a cancellation race cannot invent a completed
// cancellation or erase a delivery fact.
//
// Rule in code: FulfillmentCore transition/3 with phase/2. Commerce :cancel only
// moves :requested | :accepted | :in_transit to :cancel_requested; only dispatch
// :cancel_confirmed from :cancel_requested reaches :cancelled; dispatch may still
// deliver from :cancel_requested (delivery wins the race); phase/2 refuses every
// event once :rejected | :cancelled | :delivered | :failed. Abstracted: refs,
// versions, idempotency and actor authentication (the host's) are dropped.
module fulfillment_core_spec {
  const GUARDED: bool
  val TERMINAL = Set("rejected", "cancelled", "delivered", "failed")
  var phase: str
  var started: bool
  var confirmed: bool       // ghost: dispatch confirmed the cancellation
  var everDelivered: bool   // ghost: a delivery was admitted
  var cancelAsked: bool     // ghost: commerce requested cancellation

  action init = all { phase' = "requested", started' = false, confirmed' = false, everDelivered' = false, cancelAsked' = false }
  def allowed(from) = not(phase.in(TERMINAL)) and phase.in(from)
  action goTo(p) = all { phase' = p, started' = started, confirmed' = confirmed, everDelivered' = everDelivered, cancelAsked' = cancelAsked }

  action accept = allowed(Set("requested", "cancel_requested")) and
    goTo(if (phase == "cancel_requested") phase else "accepted")
  action reject = allowed(Set("requested", "cancel_requested")) and goTo("rejected")
  action transit = all { allowed(Set("accepted", "cancel_requested")),
    phase' = if (phase == "cancel_requested") phase else "in_transit", started' = true,
    confirmed' = confirmed, everDelivered' = everDelivered, cancelAsked' = cancelAsked }
  action deliver = all { allowed(Set("in_transit", "cancel_requested")), started,
    phase' = "delivered", started' = started, confirmed' = confirmed, everDelivered' = true, cancelAsked' = cancelAsked }
  action cancel = all {
    if (GUARDED) allowed(Set("requested", "accepted", "in_transit"))
    else phase != "cancel_requested",
    phase' = "cancel_requested", started' = started, confirmed' = confirmed,
    everDelivered' = everDelivered, cancelAsked' = true,
  }
  action confirmCancel = all { allowed(Set("cancel_requested")), phase' = "cancelled",
    started' = started, confirmed' = true, everDelivered' = everDelivered, cancelAsked' = cancelAsked }
  action stutter = goTo(phase)
  action step = any { accept, reject, transit, deliver, cancel, confirmCancel, stutter }

  val obligation = all {
    phase == "cancelled" implies confirmed,
    everDelivered implies phase == "delivered",
  }
  // Reachable race: commerce asked to cancel, then dispatch delivered anyway.
  val obligationWitness = not(cancelAsked and everDelivered)
}
module fulfillment_core { import fulfillment_core_spec(GUARDED = true).* }
module fulfillment_core_control { import fulfillment_core_spec(GUARDED = false).* }
