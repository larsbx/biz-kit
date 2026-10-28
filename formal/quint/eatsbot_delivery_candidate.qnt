// R3 abstract delivery evidence and cancellation safety for Eatsbot salvage.
// The real Dispatch authority and actual customer/driver proof are outside
// this model; booleans represent verified source observations supplied by host.
module eatsbot_delivery_candidate {
  var phase: str
  var pickupVerified: bool
  var deliveryVerified: bool
  var cancelRequested: bool
  var held: bool
  var businessCompleted: bool

  action init = all {
    phase' = "pending",
    pickupVerified' = false,
    deliveryVerified' = false,
    cancelRequested' = false,
    held' = false,
    businessCompleted' = false,
  }

  action ready = all {
    phase == "pending",
    phase' = "ready",
    pickupVerified' = pickupVerified,
    deliveryVerified' = deliveryVerified,
    cancelRequested' = cancelRequested,
    held' = held,
    businessCompleted' = businessCompleted,
  }

  action pickup = all {
    phase == "ready",
    not(cancelRequested),
    phase' = "moving",
    pickupVerified' = true,
    deliveryVerified' = deliveryVerified,
    cancelRequested' = cancelRequested,
    held' = held,
    businessCompleted' = businessCompleted,
  }

  // Requesting cancellation never destroys earlier physical pickup proof.
  action requestCancel = all {
    not(businessCompleted),
    not(cancelRequested),
    cancelRequested' = true,
    phase' = phase,
    pickupVerified' = pickupVerified,
    deliveryVerified' = deliveryVerified,
    held' = held,
    businessCompleted' = businessCompleted,
  }

  // Physical delivery can happen after a cancellation request, which
  // requires reconciliation rather than fabricated cancellation/finality.
  action observedDelivery = all {
    phase == "moving",
    pickupVerified,
    phase' = "delivered",
    deliveryVerified' = true,
    pickupVerified' = pickupVerified,
    cancelRequested' = cancelRequested,
    held' = held,
    businessCompleted' = businessCompleted,
  }

  action reconcile = all {
    phase == "delivered",
    deliveryVerified,
    pickupVerified,
    not(cancelRequested),
    not(businessCompleted),
    businessCompleted' = true,
    phase' = phase,
    pickupVerified' = pickupVerified,
    deliveryVerified' = deliveryVerified,
    cancelRequested' = cancelRequested,
    held' = held,
  }

  action uncertain = all {
    not(businessCompleted),
    held' = true,
    phase' = phase,
    pickupVerified' = pickupVerified,
    deliveryVerified' = deliveryVerified,
    cancelRequested' = cancelRequested,
    businessCompleted' = businessCompleted,
  }

  action restart = all {
    phase' = phase,
    pickupVerified' = pickupVerified,
    deliveryVerified' = deliveryVerified,
    cancelRequested' = cancelRequested,
    held' = held,
    businessCompleted' = businessCompleted,
  }

  action step = any { ready, pickup, requestCancel, observedDelivery, reconcile, uncertain, restart }

  val noPrematureCompletion = businessCompleted implies (
    pickupVerified and deliveryVerified and not(cancelRequested)
  )
  val noFabricatedProof = (phase == "delivered") implies deliveryVerified
  val noCancellationErasure = (cancelRequested and deliveryVerified)
    implies not(businessCompleted)
  val safety = noPrematureCompletion and noFabricatedProof
    and noCancellationErasure

  val noDeliveryWitness = not(phase == "delivered")
  val noHeldWitness = not(held)
}
