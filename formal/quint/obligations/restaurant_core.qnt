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

// restaurant_core, key fence: "Within a chapter no grant holds a declared role
// key, a Dispatch key is none of the chapter's device keys and serves one
// tenant; within a merchant a key is granted once."
//
// Models the fence RestaurantCore.Admission.check/2 adds to admit/3 for
// RestaurantDeviceGrantedV1 and RestaurantDispatchGrantedV1
// (key_conflicts/2: apart, then once), and the converse for RoleKeyDeclared
// (role_key_conflicts/3, applied by CoopSubstrate.KeyFence from Validity).
// Abstracted: signatures (governance signs every grant), key ids and admit/3's
// other refusals, and grant revocation: a revoked grant stays in the state,
// so revoking never changes which keys are held and cannot break the
// obligation. A role revocation forgets that declaration (Membership deletes
// it), so a revoked role key may later be granted. GUARDED switches the fence
// off.
module restaurant_key_fence_spec {
  const GUARDED: bool

  pure val CHAPTERS = Set("a", "b")
  pure val MERCHANTS = Set("m1", "m2")
  pure val KEYS = Set("k1", "k2", "k3")
  pure val TENANTS = Set("t1", "t2")
  // declaration slots (role, key id)
  pure val SLOTS = Set("governance", "steward")

  type Grant = { chapter: str, merchant: str, key: str, dispatch: bool, tenant: str }

  var grants: Set[Grant]
  // currently declared role keys: (chapter, slot, key)
  var roleKeys: Set[(str, str, str)]

  action init = all { grants' = Set(), roleKeys' = Set() }

  def roleKey(c: str, k: str): bool = roleKeys.exists(r => r._1 == c and r._3 == k)

  action grant(c: str, m: str, k: str, d: bool, t: str): bool = {
    val held = grants.filter(h => h.chapter == c and h.key == k)
    val apart =
      not(roleKey(c, k)) and
        (if (d) held.forall(h => h.dispatch and h.tenant == t) else held.forall(h => not(h.dispatch)))
    val once = held.forall(h => h.merchant != m)
    all {
      not(GUARDED) or (apart and once),
      grants' = grants.union(Set({ chapter: c, merchant: m, key: k, dispatch: d, tenant: if (d) t else "" })),
      roleKeys' = roleKeys,
    }
  }

  action declareRole(c: str, s: str, k: str): bool = all {
    not(roleKeys.exists(r => r._1 == c and r._2 == s)),
    not(GUARDED) or not(grants.exists(g => g.chapter == c and g.key == k)),
    roleKeys' = roleKeys.union(Set((c, s, k))),
    grants' = grants,
  }

  action revokeRole(c: str, s: str): bool = all {
    roleKeys.exists(r => r._1 == c and r._2 == s),
    roleKeys' = roleKeys.filter(r => not(r._1 == c and r._2 == s)),
    grants' = grants,
  }

  action step = nondet c = CHAPTERS.oneOf()
    nondet m = MERCHANTS.oneOf()
    nondet k = KEYS.oneOf()
    nondet d = Set(true, false).oneOf()
    nondet t = TENANTS.oneOf()
    nondet s = SLOTS.oneOf()
    any { grant(c, m, k, d, t), declareRole(c, s, k), revokeRole(c, s) }

  val obligation =
    grants.forall(g => grants.forall(h =>
      (g != h and g.chapter == h.chapter and g.key == h.key) implies
        (g.merchant != h.merchant and g.dispatch == h.dispatch and (not(g.dispatch) or g.tenant == h.tenant))))
    and grants.forall(g => not(roleKey(g.chapter, g.key)))

  // One Dispatch key serves two merchants of its tenant.
  val obligationWitness = not(grants.exists(g => grants.exists(h =>
    g.dispatch and h.dispatch and g.chapter == h.chapter and g.key == h.key and g.merchant != h.merchant)))
}

module restaurant_key_fence {
  import restaurant_key_fence_spec(GUARDED = true).*
}

module restaurant_key_fence_control {
  import restaurant_key_fence_spec(GUARDED = false).*
}
