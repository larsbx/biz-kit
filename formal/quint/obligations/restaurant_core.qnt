// restaurant_core: "A restaurant event is admitted only when signed by a key a
// governance grant authorized for it: a restaurant device for that action, or
// the merchant's Dispatch transport key for a transport step."
//
// Models RestaurantCore.Admission.admit/3 (apps/restaurant_core/lib/
// restaurant_core/admission.ex):
// - RestaurantDeviceGrantedV1 is admitted only when governance/3 finds the
//   signer's key declared as the chapter's governance key, and only once per key.
// - RestaurantOrderPlacedV1 needs device/3 with :checkout in the grant's actions.
// - RestaurantOrderStepV1 needs device/3 (granted key with a matching pubkey)
//   and OrderCore.Lifecycle.authorized?/3 (the action in allowed_actions).
// - RestaurantTransportGrantedV1 is admitted only when governance-signed,
//   once per key, and only for a key no device grant holds; a device grant is
//   likewise refused for a transport key (:key_not_separate, both directions).
// - RestaurantTransportStepV1 needs transport_key/3: a granted transport key
//   with a matching pubkey. Device grants never authorize it.
// - A transport grant is refused for a declared role key, and RoleKeyDeclared
//   (CoopSubstrate.Protocol.Validity) for a transport key, in either order.
// Abstracted: one chapter and merchant, keys as names drawn from one set (so a
// key may be offered to both registries), signature validity as `keyMatches`,
// the order lifecycle and the handoff relation (restaurant_delivery.qnt).
// GUARDED switches off the grant, action, separation and transport checks.
// Role-key declaration is governance's (abstracted as always signed).
module restaurant_core_spec {
  const GUARDED: bool

  pure val KEYS = Set("board", "till", "dispatch")
  pure val ACTIONS = Set("checkout", "accept")

  // device -> granted actions; only governance-signed grants enter.
  var grants: str -> Set[str]
  // granted Dispatch transport keys; only governance-signed grants enter.
  var transportKeys: Set[str]
  // admitted device-signed events: (device, action, keyMatches)
  var admitted: List[(str, str, bool)]
  // admitted transport steps: (key, keyMatches)
  var admittedTransport: List[(str, bool)]
  // keys declared for a governance, steward or checkpoint role
  var roleKeys: Set[str]

  action init = all {
    grants' = Map(), transportKeys' = Set(), admitted' = [], admittedTransport' = [],
    roleKeys' = Set(),
  }

  action declareRole(key: str): bool = all {
    not(roleKeys.contains(key)),
    not(GUARDED) or not(transportKeys.contains(key)),
    roleKeys' = roleKeys.union(Set(key)),
    grants' = grants, transportKeys' = transportKeys, admitted' = admitted,
    admittedTransport' = admittedTransport,
  }

  action grant(device: str, actions: Set[str], governanceSigned: bool): bool = all {
    governanceSigned, not(grants.keys().contains(device)),
    not(GUARDED) or not(transportKeys.contains(device)),
    grants' = grants.put(device, actions), admitted' = admitted,
    transportKeys' = transportKeys, admittedTransport' = admittedTransport, roleKeys' = roleKeys,
  }

  action grantTransport(key: str, governanceSigned: bool): bool = all {
    governanceSigned, not(transportKeys.contains(key)),
    not(GUARDED) or not(grants.keys().contains(key)),
    not(GUARDED) or not(roleKeys.contains(key)),
    transportKeys' = transportKeys.union(Set(key)),
    grants' = grants, admitted' = admitted, admittedTransport' = admittedTransport,
    roleKeys' = roleKeys,
  }

  action transportEvent(key: str, keyMatches: bool): bool = all {
    not(GUARDED) or (keyMatches and transportKeys.contains(key)),
    admittedTransport' = admittedTransport.append((key, keyMatches)),
    grants' = grants, transportKeys' = transportKeys, admitted' = admitted, roleKeys' = roleKeys,
  }

  action deviceEvent(device: str, act: str, keyMatches: bool): bool = {
    val authorized = keyMatches and grants.keys().contains(device)
      and grants.get(device).contains(act)
    all {
      not(GUARDED) or authorized,
      admitted' = admitted.append((device, act, keyMatches)),
      grants' = grants, transportKeys' = transportKeys, admittedTransport' = admittedTransport,
      roleKeys' = roleKeys,
    }
  }

  action step = nondet d = KEYS.oneOf()
    nondet a = ACTIONS.oneOf()
    nondet acts = ACTIONS.powerset().oneOf()
    nondet ok = Set(true, false).oneOf()
    any {
      grant(d, acts, ok), deviceEvent(d, a, ok),
      grantTransport(d, ok), transportEvent(d, ok), declareRole(d),
    }

  val obligation = and {
    admitted.indices().forall(i =>
      val e = admitted[i]
      e._3 and grants.keys().contains(e._1) and grants.get(e._1).contains(e._2)),
    admittedTransport.indices().forall(i =>
      admittedTransport[i]._2 and transportKeys.contains(admittedTransport[i]._1)),
    transportKeys.intersect(grants.keys()) == Set(),
    transportKeys.intersect(roleKeys) == Set(),
  }

  // A granted device's event was admitted.
  val obligationWitness = admitted.length() == 0
}

module restaurant_core {
  import restaurant_core_spec(GUARDED = true).*
}

module restaurant_core_control {
  import restaurant_core_spec(GUARDED = false).*
}
