// Source-bound commercial *business* admission: bounded abstract safety model.
//
// NO contractual validity, signatures, jurisdiction decisions, bank payment,
// cryptographic hash collision resistance, or financial settlement is proved.
// The input booleans stand for independently verified source-set binding,
// current agency authority and legal/policy eligibility. Production must not
// accept those flags from a caller. The state machine assumes one serialized,
// durable admission authority per scope, not distributed multi-node ACID.
//
// Sources 1..3 abstract distinct immutable (chapter, original obligation ID)
// keys; an identical-total substitution is a different key. Intent IDs are
// also scoped. No financial transfer or platform-issued credit is modeled.
module commercial_source_fence_spec {
  const GUARDED: bool

  type Entry = {
    intent: int,
    left: int,
    right: int,
    bound: bool,
    agency: bool,
    legal: bool,
  }

  var records: List[Entry]
  var consumed: Set[int]
  var refusals: int

  pure val KEYS = 1.to(3)

  action init = all {
    records' = [],
    consumed' = Set(),
    refusals' = 0,
  }

  action attempt = {
    nondet intent = KEYS.oneOf()
    nondet left = KEYS.oneOf()
    nondet right = KEYS.oneOf()
    nondet bound = Set(true, false).oneOf()
    nondet agency = Set(true, false).oneOf()
    nondet legal = Set(true, false).oneOf()

    val distinct = left != right
    val freshIntent = not(records.indices().exists(i => records[i].intent == intent))
    val freshSources = not(consumed.contains(left)) and not(consumed.contains(right))
    val eligible = distinct and freshIntent and freshSources and bound and agency and legal
    val accept = if (GUARDED) eligible else true

    all {
      records' =
        if (accept) records.append({
          intent: intent, left: left, right: right,
          bound: bound, agency: agency, legal: legal
        }) else records,
      consumed' = if (accept) consumed.union(Set(left, right)) else consumed,
      refusals' = if (accept) refusals else refusals + 1,
    }
  }

  action crashRestart = all {
    records' = records,
    consumed' = consumed,
    refusals' = refusals,
  }

  action step = any { attempt, crashRestart }

  val acceptedVerified = records.indices().forall(i =>
    records[i].bound and records[i].agency and records[i].legal
    and records[i].left != records[i].right)

  val noSourceDoubleUse = records.indices().forall(i =>
    records.indices().forall(j =>
      i == j or
        (records[i].left != records[j].left
         and records[i].left != records[j].right
         and records[i].right != records[j].left
         and records[i].right != records[j].right)))

  val noIntentReplay = records.indices().forall(i =>
    records.indices().forall(j =>
      i == j or records[i].intent != records[j].intent))

  val consumedMatchesHistory = KEYS.forall(key =>
    consumed.contains(key) ==
      records.indices().exists(i =>
        records[i].left == key or records[i].right == key))

  val safety = acceptedVerified and noSourceDoubleUse
    and noIntentReplay and consumedMatchesHistory

  // Prove nonvacuity by reaching an accepted record and also a refusal.
  val noAcceptedWitness = not(records.length() > 0)
  val noRefusalWitness = not(refusals > 0)
}

module commercial_source_fence {
  import commercial_source_fence_spec(GUARDED = true).*
}

module commercial_source_fence_control {
  import commercial_source_fence_spec(GUARDED = false).*
}
