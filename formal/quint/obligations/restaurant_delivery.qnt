// restaurant_core (delivery handoff): "A delivery order's transport states come
// only from Dispatch's proof-backed steps and its kitchen states only from the
// restaurant (I8); every admitted event joins coupled (order, handoff) pairs."
//
// Models the joint steps of RestaurantCore.Coupling.rows/0 (apps/restaurant_core/
// lib/restaurant_core/coupling.ex) as data. RestaurantCore.Delivery admits a
// restaurant or Dispatch fact only as one of these rows, from its source pair to
// its target. Abstracted: one delivery order, the handoff as its Coupling view,
// FulfillmentCore and Kitchen as the rows they accept; versions, idempotency and
// signatures are the Elixir suite's. GUARDED = false also admits the six cells
// the pinned reducers accept but admission refuses (Coupling.strict/0), and a
// completion without proof.
module restaurant_delivery_spec {
  const GUARDED: bool

  type Pair = (str, str)
  type Row = { src: Pair, by: str, op: str, dst: Pair, proof: bool }

  pure val OWNED = Set("dispatched", "completed", "failed")
  // Views only Dispatch's steps enter; requested and withdrawn are the restaurant's.
  pure val DISPATCH_VIEWS =
    Set("accepted", "in_transit", "rejected", "cancelled", "delivered",
        "failed_before_pickup", "failed_in_transit")

  pure val COUPLED: Set[Pair] = Set(
    ("placed", "none"), ("accepted", "none"), ("preparing", "none"), ("ready", "none"),
    ("cancelled", "none"),
    ("ready", "requested"), ("ready", "accepted"), ("ready", "withdrawn"),
    ("ready", "cancel_pending"), ("ready", "rejected"), ("ready", "cancelled"),
    ("ready", "failed_before_pickup"),
    ("dispatched", "in_transit"), ("completed", "delivered"), ("failed", "failed_in_transit"),
    ("cancelled", "withdrawn"), ("cancelled", "rejected"), ("cancelled", "cancelled"),
    ("cancelled", "failed_before_pickup"))

  pure def r(src: Pair, by: str, op: str, dst: Pair, proof: bool): Row =
    { src: src, by: by, op: op, dst: dst, proof: proof }

  pure val ROWS: Set[Row] = Set(
    r(("placed", "none"), "restaurant", "accept", ("accepted", "none"), false),
    r(("accepted", "none"), "restaurant", "start_preparing", ("preparing", "none"), false),
    r(("preparing", "none"), "restaurant", "mark_ready", ("ready", "none"), false),
    r(("placed", "none"), "restaurant", "cancel", ("cancelled", "none"), false),
    r(("accepted", "none"), "restaurant", "cancel", ("cancelled", "none"), false),
    r(("preparing", "none"), "restaurant", "cancel", ("cancelled", "none"), false),
    r(("ready", "none"), "restaurant", "cancel", ("cancelled", "none"), false),
    r(("ready", "withdrawn"), "restaurant", "cancel", ("cancelled", "withdrawn"), false),
    r(("ready", "rejected"), "restaurant", "cancel", ("cancelled", "rejected"), false),
    r(("ready", "cancelled"), "restaurant", "cancel", ("cancelled", "cancelled"), false),
    r(("ready", "failed_before_pickup"), "restaurant", "cancel",
      ("cancelled", "failed_before_pickup"), false),
    r(("ready", "none"), "restaurant", "request", ("ready", "requested"), false),
    r(("ready", "rejected"), "restaurant", "request", ("ready", "requested"), false),
    r(("ready", "cancelled"), "restaurant", "request", ("ready", "requested"), false),
    r(("ready", "failed_before_pickup"), "restaurant", "request", ("ready", "requested"), false),
    r(("ready", "requested"), "restaurant", "withdraw", ("ready", "withdrawn"), false),
    r(("ready", "accepted"), "restaurant", "withdraw", ("ready", "cancel_pending"), false),
    r(("ready", "requested"), "dispatch", "accept", ("ready", "accepted"), false),
    r(("ready", "withdrawn"), "dispatch", "accept", ("ready", "cancel_pending"), false),
    r(("ready", "requested"), "dispatch", "reject", ("ready", "rejected"), false),
    r(("ready", "withdrawn"), "dispatch", "reject", ("ready", "rejected"), false),
    r(("cancelled", "withdrawn"), "dispatch", "reject", ("cancelled", "rejected"), false),
    r(("ready", "withdrawn"), "dispatch", "cancel_confirmed", ("ready", "cancelled"), false),
    r(("ready", "cancel_pending"), "dispatch", "cancel_confirmed", ("ready", "cancelled"), false),
    r(("cancelled", "withdrawn"), "dispatch", "cancel_confirmed", ("cancelled", "cancelled"), false),
    r(("ready", "accepted"), "dispatch", "in_transit", ("dispatched", "in_transit"), false),
    r(("dispatched", "in_transit"), "dispatch", "delivered", ("completed", "delivered"), true),
    r(("ready", "accepted"), "dispatch", "failed", ("ready", "failed_before_pickup"), true),
    r(("ready", "cancel_pending"), "dispatch", "failed", ("ready", "failed_before_pickup"), true),
    r(("dispatched", "in_transit"), "dispatch", "failed", ("failed", "failed_in_transit"), true))

  // What the pinned reducers alone would admit where admission refuses, and a
  // completion without proof.
  pure val LOOSE: Set[Row] = Set(
    r(("ready", "requested"), "restaurant", "cancel", ("cancelled", "requested"), false),
    r(("ready", "accepted"), "restaurant", "cancel", ("cancelled", "accepted"), false),
    r(("ready", "cancel_pending"), "restaurant", "cancel", ("cancelled", "cancel_pending"), false),
    r(("dispatched", "in_transit"), "restaurant", "withdraw", ("dispatched", "cancel_in_transit"), false),
    r(("ready", "cancel_pending"), "dispatch", "in_transit", ("dispatched", "cancel_in_transit"), false),
    r(("cancelled", "withdrawn"), "dispatch", "accept", ("cancelled", "cancel_pending"), false),
    r(("dispatched", "in_transit"), "dispatch", "delivered", ("completed", "delivered"), false))

  var order: str
  var view: str
  // The last order move and the last handoff view change, with who signed it.
  var orderMove: (str, str, str)
  var viewMove: (str, str, str)
  var proofCited: bool

  action init = all {
    order' = "placed", view' = "none",
    orderMove' = ("placed", "placed", "none"), viewMove' = ("none", "none", "none"),
    proofCited' = false,
  }

  action take(row: Row): bool = all {
    (order, view) == row.src,
    order' = row.dst._1, view' = row.dst._2,
    orderMove' = if (row.dst._1 != order) (order, row.dst._1, row.by) else orderMove,
    viewMove' = if (row.dst._2 != view) (view, row.dst._2, row.by) else viewMove,
    proofCited' = if (row.dst._1 != order) row.proof else proofCited,
  }

  action step = {
    val choices = (if (GUARDED) ROWS else ROWS.union(LOOSE)).filter(row => row.src == (order, view))
    all { choices.size() > 0, nondet row = choices.oneOf() take(row) }
  }

  val obligation = and {
    COUPLED.contains((order, view)),
    orderMove._1 == orderMove._2 or (OWNED.contains(orderMove._2) iff orderMove._3 == "dispatch"),
    (OWNED.contains(order) and order != "dispatched") implies proofCited,
    Set("requested", "withdrawn").contains(viewMove._2) implies viewMove._3 == "restaurant",
    DISPATCH_VIEWS.contains(viewMove._2) implies viewMove._3 == "dispatch",
  }

  // A delivery is completed.
  val obligationWitness = order != "completed"
}

module restaurant_delivery {
  import restaurant_delivery_spec(GUARDED = true).*
}

module restaurant_delivery_control {
  import restaurant_delivery_spec(GUARDED = false).*
}
