// Three accepted events: event 1 requires two distinct operational effects,
// event 2 requires no effects but MUST have an explicit no-op receipt, and
// event 3 requires one effect. No progress without durable full-bundle proof.

module effect_bundles {
  pure val MAX = 3

  var head: int
  var cursor: int
  var effects: Set[str]
  var receipts: Set[int]

  def bundleComplete(n: int): bool =
    if (n == 1) effects.contains("one-A") and effects.contains("one-B")
    else if (n == 2) true
    else if (n == 3) effects.contains("three-A")
    else false

  action init = all {
    head' = 0,
    cursor' = 0,
    effects' = Set(),
    receipts' = Set(),
  }

  action append = all {
    head < MAX,
    head' = head + 1,
    cursor' = cursor,
    effects' = effects,
    receipts' = receipts,
  }

  action effect = {
    nondet e = Set("one-A", "one-B", "three-A").oneOf()
    all {
      if (e == "three-A") head >= 3 else head >= 1,
      effects' = effects.union(Set(e)),
      head' = head,
      cursor' = cursor,
      receipts' = receipts,
    }
  }

  action durableReceipt = {
    nondet n = 1.to(MAX).oneOf()
    all {
      n <= head,
      bundleComplete(n),
      receipts' = receipts.union(Set(n)),
      head' = head,
      cursor' = cursor,
      effects' = effects,
    }
  }

  action checkpoint = all {
    cursor < head,
    receipts.contains(cursor + 1),
    bundleComplete(cursor + 1),
    cursor' = cursor + 1,
    head' = head,
    effects' = effects,
    receipts' = receipts,
  }

  action crashRestart = all {
    head' = head,
    cursor' = cursor,
    effects' = effects,
    receipts' = receipts,
  }

  action step = any { append, effect, durableReceipt, checkpoint, crashRestart }

  val prefixSafe = cursor <= head and
    range(1, MAX + 1).forall(i =>
      (i <= cursor) implies (receipts.contains(i) and bundleComplete(i)))

  val effectsFromAccepted =
    effects.forall(e => if (e == "three-A") head >= 3 else head >= 1)

  val receiptsFromAccepted = receipts.forall(i => i >= 1 and i <= head)

  val safety = prefixSafe and effectsFromAccepted and receiptsFromAccepted

  // Reachable midway through registration: it must NOT advance the cursor.
  val noPartialBundle = not(head >= 1 and effects.contains("one-A")
    and not(effects.contains("one-B")) and cursor == 0)

  // No-effect event 2 needs a receipt even after event 1 has been processed.
  val noNoopReceipt = not(head >= 2 and receipts.contains(2))
}
