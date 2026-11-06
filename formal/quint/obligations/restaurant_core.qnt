// restaurant_core: "A restaurant event is admitted only when signed by a
// device a governance grant authorized for that action."
//
// Models RestaurantCore.Admission.admit/3 (apps/restaurant_core/lib/
// restaurant_core/admission.ex):
// - RestaurantDeviceGrantedV1 is admitted only when governance/3 finds the
//   signer's key declared as the chapter's governance key, and only once per key.
// - RestaurantOrderPlacedV1 needs device/3 with :checkout in the grant's actions.
// - RestaurantOrderStepV1 needs device/3 (granted key with a matching pubkey)
//   and OrderCore.Lifecycle.authorized?/3 (the action in allowed_actions).
// Abstracted: one chapter and merchant, keys as device names, signature
// validity as `keyMatches`, the order lifecycle itself. GUARDED switches off
// the device-grant and action checks.
module restaurant_core_spec {
  const GUARDED: bool

  pure val DEVICES = Set("board", "till")
  pure val ACTIONS = Set("checkout", "accept")

  // device -> granted actions; only governance-signed grants enter.
  var grants: str -> Set[str]
  // admitted device-signed events: (device, action, keyMatches)
  var admitted: List[(str, str, bool)]

  action init = all { grants' = Map(), admitted' = [] }

  action grant(device: str, actions: Set[str], governanceSigned: bool): bool = all {
    governanceSigned, not(grants.keys().contains(device)),
    grants' = grants.put(device, actions), admitted' = admitted,
  }

  action deviceEvent(device: str, act: str, keyMatches: bool): bool = {
    val authorized = keyMatches and grants.keys().contains(device)
      and grants.get(device).contains(act)
    all {
      not(GUARDED) or authorized,
      admitted' = admitted.append((device, act, keyMatches)),
      grants' = grants,
    }
  }

  action step = nondet d = DEVICES.oneOf()
    nondet a = ACTIONS.oneOf()
    nondet acts = ACTIONS.powerset().oneOf()
    nondet ok = Set(true, false).oneOf()
    any { grant(d, acts, ok), deviceEvent(d, a, ok) }

  val obligation = admitted.indices().forall(i =>
    val e = admitted[i]
    e._3 and grants.keys().contains(e._1) and grants.get(e._1).contains(e._2))

  // A granted device's event was admitted.
  val obligationWitness = admitted.length() == 0
}

module restaurant_core {
  import restaurant_core_spec(GUARDED = true).*
}

module restaurant_core_control {
  import restaurant_core_spec(GUARDED = false).*
}
