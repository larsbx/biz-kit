// eatsbot_core: "Preserve legacy commerce behavior under independent replay
// characterization".
//
// Formalized over the delivery lifecycle: replaying the recorded state history
// from Init must reproduce the live delivery state, and every recorded step
// must be a legacy transition. Rule: EatsbotCore.Deliveries.UpdateHistory
// accepts a state change only if Transitions.valid?/2 (the 13-edge table in
// transitions.ex) and records it with DeliveryStateChanges.add_to_state_history!.
// GUARDED: the history row is written atomically with the state change.
// Steps are drawn only from the table, which models valid?/2 (enforced).
// Abstracted: states as names; history as the state it replays to.
// Enforced: UpdateHistory writes the history row in Ash.Changeset.after_action,
// inside the state change's transaction, so a failed history write rolls the
// state back (DeliveryTest "a state change whose history row fails to write
// is not committed"). Telemetry stays in after_transaction (on commit only).
module eatsbot_core_spec {
  const GUARDED: bool
  pure val EDGES = Set(
    ("Init", "In_Preparation"), ("Init", "Delivery_Aborted"),
    ("In_Preparation", "Ready_To_Pickup"), ("In_Preparation", "Delivery_Aborted"),
    ("Ready_To_Pickup", "In_Delivery"), ("Ready_To_Pickup", "Delivery_Aborted"),
    ("Delivery_Aborted", "Stale_Delivery_Aborted"),
    ("In_Delivery", "Delivery_With_Problems"), ("In_Delivery", "Delivery_Done"),
    ("In_Delivery", "Stale_Delivery_With_Problems"),
    ("Delivery_With_Problems", "In_Delivery"),
    ("Delivery_With_Problems", "Stale_Delivery_With_Problems"),
    ("Delivery_Done", "Stale_Delivery_Done"))
  var live: str
  var replayed: str       // state obtained by replaying the recorded history
  var pending: str        // history row not yet written ("" when none)

  action init = all { live' = "Init", replayed' = "Init", pending' = "" }
  action transition = all { pending == "", EDGES.exists(e => e._1 == live),
    nondet e = EDGES.filter(e => e._1 == live).oneOf()
    all { live' = e._2,
      replayed' = if (GUARDED) e._2 else replayed,
      pending' = if (GUARDED) "" else e._2 } }
  action recordHistory = all { pending != "", replayed' = pending, pending' = "",
    live' = live }
  action crashBeforeHistory = all { pending != "", pending' = "", replayed' = replayed,
    live' = live }
  // Stale_* states are terminal; the delivery stays there.
  action rest = all { pending == "", not(EDGES.exists(e => e._1 == live)),
    live' = live, replayed' = replayed, pending' = pending }
  action step = any { transition, recordHistory, crashBeforeHistory, rest }

  val obligation = pending == "" implies replayed == live
  val obligationWitness = not(live == "Delivery_Done")
}
module eatsbot_core { import eatsbot_core_spec(GUARDED = true).* }
module eatsbot_core_control { import eatsbot_core_spec(GUARDED = false).* }
