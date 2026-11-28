// coop_substrate: "Accepted append always binds canonical bytes, authorization,
// scope and replay identity."
//
// Models CoopSubstrate.Log.handle_call({:append, ...}) (apps/coop_substrate/lib/
// coop_substrate/log.ex): verify_batch/1 (Envelope.verify/1: every declared
// signer signed the canonical signing bytes; batch event IDs unique),
// duplicate/2 (a replayed event ID returns the earlier result and appends
// nothing), verify_validity/2 (TypeRegistry.validity_check/2 against the gate:
// authorization and scope), then assign_chains/2 (stream_id derived from type,
// chapter and payload; sequence and previous-hash links).
// Abstracted: crypto as a boolean, the gate as a boolean, a hash as an integer,
// one envelope per batch, one stream. GUARDED switches off the three checks.
module coop_substrate_spec {
  const GUARDED: bool

  type Entry = { id: int, signed: bool, authorized: bool, derivedStream: bool,
               seq: int, prev: int, hash: int }

  var log: List[Entry]

  pure val IDS = 1.to(3)

  action init = log' = []

  pure def hashOf(id: int, seq: int, prev: int): int = id * 100 + seq * 10 + prev % 10

  action admit(id: int, signed: bool, authorized: bool): bool = {
    val seen = log.indices().exists(i => log[i].id == id)
    val accept = not(GUARDED) or (signed and authorized and not(seen))
    val prev = if (log.length() == 0) 0 else log[log.length() - 1].hash
    val seq = log.length() + 1
    if (accept)
      log' = log.append({ id: id, signed: signed, authorized: authorized, derivedStream: true,
                          seq: seq, prev: prev, hash: hashOf(id, seq, prev) })
    else log' = log
  }

  action step = nondet id = IDS.oneOf()
    nondet signed = Set(true, false).oneOf()
    nondet authorized = Set(true, false).oneOf()
    admit(id, signed, authorized)

  // Every accepted record carries verified canonical bytes, an authorized
  // scope, a derived stream, a unique replay identity and an unbroken chain.
  val obligation = log.indices().forall(i => all {
    log[i].signed, log[i].authorized, log[i].derivedStream,
    log[i].seq == i + 1,
    log[i].prev == (if (i == 0) 0 else log[i - 1].hash),
    log.indices().forall(j => j != i implies log[j].id != log[i].id),
  })

  // Two records chained: a real append history exists.
  val obligationWitness = log.length() < 2
}

module coop_substrate {
  import coop_substrate_spec(GUARDED = true).*
}

module coop_substrate_control {
  import coop_substrate_spec(GUARDED = false).*
}

// coop_substrate, chapter key fence: "Within a chapter, a key newly bound at
// append time is bound by no other holder; deactivating a procurement slot is
// never refused."
//
// Models CoopSubstrate.KeyFence.check/2, the last step of Validity.check/2
// (the append gate and Commands preflight, never a fold). Holders
// (KeyFence.holder/1): "core" (declared role keys and restaurant grants, whose
// mutual rules RestaurantCore states and restaurant_key_fence models), each
// DispatchCore dispatcher grant {tenant, key_id}, each cooperative's
// procurement Dispatch route, and the procurement operators (one holder across
// cooperatives). A binding counts forever, except that a role revocation
// forgets a role binding. A procurement event with active false claims nothing.
// The ledger may start with bindings admitted before the fence (`fresh` false),
// which replay unchanged; the obligation is about bindings admitted by the
// fence. GUARDED switches it off.
module key_fence_spec {
  const GUARDED: bool

  pure val CHAPTERS = Set("a", "b")
  pure val KEYS = Set("k1", "k2")
  // (holder, slot): a slot is one place a holder binds a key
  pure val PLACES = Set(
    ("core", "role"), ("core", "grant"),
    ("dispatcher:t1:x1", "dispatcher:t1:x1"), ("dispatcher:t2:x2", "dispatcher:t2:x2"),
    ("route:c1", "route:c1"), ("route:c2", "route:c2"),
    ("operator", "operator:c1"), ("operator", "operator:c2"))
  pure val PROCUREMENT_SLOTS = Set("route:c1", "route:c2", "operator:c1", "operator:c2")

  type Bind = { chapter: str, key: str, holder: str, slot: str, fresh: bool }

  var binds: Set[Bind]
  // procurement slots that have been deactivated: (chapter, slot)
  var deactivated: Set[(str, str)]

  // History written before the fence: one key both a route and an operator key.
  pure val PRE_FENCE = Set(
    { chapter: "a", key: "k1", holder: "route:c1", slot: "route:c1", fresh: false },
    { chapter: "a", key: "k1", holder: "operator", slot: "operator:c1", fresh: false })

  action init = all {
    nondet seeded = Set(true, false).oneOf()
    binds' = if (seeded) PRE_FENCE else Set(),
    deactivated' = Set(),
  }

  def free(c: str, k: str, h: str): bool =
    binds.forall(b => (b.chapter == c and b.key == k) implies b.holder == h)

  action bind(c: str, k: str, h: str, s: str): bool = all {
    not(GUARDED) or free(c, k, h),
    binds' = binds.union(Set({ chapter: c, key: k, holder: h, slot: s, fresh: true })),
    deactivated' = deactivated,
  }

  // RoleKeyRevoked: the registry forgets the declaration.
  action revokeRole(c: str, k: str): bool = all {
    binds.exists(b => b.chapter == c and b.key == k and b.slot == "role"),
    binds' = binds.filter(b => not(b.chapter == c and b.key == k and b.slot == "role")),
    deactivated' = deactivated,
  }

  // A route or operator re-sent with active false: no claim, never refused.
  action deactivate(c: str, s: str): bool = all {
    binds.exists(b => b.chapter == c and b.slot == s),
    deactivated' = deactivated.union(Set((c, s))),
    binds' = binds,
  }

  action step = nondet c = CHAPTERS.oneOf()
    nondet k = KEYS.oneOf()
    nondet p = PLACES.oneOf()
    nondet s = PROCUREMENT_SLOTS.oneOf()
    any { bind(c, k, p._1, p._2), revokeRole(c, k), deactivate(c, s) }

  val obligation = binds.forall(b => b.fresh implies binds.forall(o =>
    (o.chapter == b.chapter and o.key == b.key) implies o.holder == b.holder))

  // One operator key serves two cooperatives, admitted by the fence.
  val obligationWitness = not(binds.exists(b => binds.exists(o =>
    b.fresh and o.fresh and b.holder == "operator" and o.holder == "operator" and
      b.chapter == o.chapter and b.key == o.key and b.slot != o.slot)))

  // One key bound by two holders in two chapters, both admitted by the fence.
  val crossChapterWitness = not(binds.exists(b => binds.exists(o =>
    b.fresh and o.fresh and b.key == o.key and b.chapter != o.chapter and
      b.holder != o.holder)))

  // A slot whose key collides from before the fence is deactivated.
  val remediationWitness = not(deactivated.exists(d => binds.exists(b => binds.exists(o =>
    b.chapter == d._1 and b.slot == d._2 and o.chapter == b.chapter and o.key == b.key and
      o.holder != b.holder))))
}

module key_fence {
  import key_fence_spec(GUARDED = true).*
}

module key_fence_control {
  import key_fence_spec(GUARDED = false).*
}
