// Obligation (dispatch_core): cancellation cannot fabricate or erase
// confirmed physical transport facts.
//
// Rule in code: DispatchCore.LastMile.transition/3. Commerce :cancel only sets
// cancel_requested?; dispatch :cancel_confirmed is admitted only in phases
// :awaiting_ready and :ready_for_pickup, i.e. before a pickup is recorded.
// pickup_ref and delivery_proof_ref are never cleared, and :delivered and
// :cancelled are terminal. Abstracted: refs are booleans; idempotency,
// versions and producer authentication are the host's (see apply/4).
module dispatch_core_spec {
  const GUARDED: bool
  var phase: str
  var cancelRequested: bool
  var pickupRef: bool
  var proofRef: bool
  var pickedUp: bool   // ghost: a dispatch :picked_up was admitted
  var delivered: bool  // ghost: a dispatch :delivered was admitted

  action init = all {
    phase' = "awaiting_ready", cancelRequested' = false, pickupRef' = false,
    proofRef' = false, pickedUp' = false, delivered' = false,
  }
  action move(p) = all { phase' = p, cancelRequested' = cancelRequested, pickupRef' = pickupRef,
    proofRef' = proofRef, pickedUp' = pickedUp, delivered' = delivered }
  def open = not(phase.in(Set("delivered", "cancelled")))

  action ready = phase == "awaiting_ready" and move("ready_for_pickup")
  action pickUp = all { phase == "ready_for_pickup", phase' = "in_transit", pickupRef' = true,
    pickedUp' = true, cancelRequested' = cancelRequested, proofRef' = proofRef, delivered' = delivered }
  action deliver = all { phase == "in_transit", phase' = "delivered", proofRef' = true,
    delivered' = true, cancelRequested' = cancelRequested, pickupRef' = pickupRef, pickedUp' = pickedUp }
  action cancel = all { open, not(cancelRequested), cancelRequested' = true, phase' = phase,
    pickupRef' = pickupRef, proofRef' = proofRef, pickedUp' = pickedUp, delivered' = delivered }
  action confirmCancel = all {
    cancelRequested,
    if (GUARDED) phase.in(Set("awaiting_ready", "ready_for_pickup")) else open,
    move("cancelled"),
  }
  action stutter = move(phase)
  action step = any { ready, pickUp, deliver, cancel, confirmCancel, stutter }

  // No erasure: a pickup or delivery that happened stays recorded and is never
  // overwritten by a cancellation. No fabrication: refs exist only if it happened.
  val obligation = all {
    pickedUp iff pickupRef, delivered iff proofRef,
    phase == "cancelled" implies not(pickedUp),
    delivered implies phase == "delivered",
  }
  val obligationWitness = not(cancelRequested and pickedUp)
}
module dispatch_core { import dispatch_core_spec(GUARDED = true).* }
module dispatch_core_control { import dispatch_core_spec(GUARDED = false).* }
