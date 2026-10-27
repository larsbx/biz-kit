// Three accepted events: event 1 requires two distinct operational effects,
// event 2 requires no effects but MUST have an explicit no-op receipt, and
// event 3 requires one effect. No progress without durable full-bundle proof.

module effect_bundles {
  pure val MAX = 3

  var ledgerHead: int
  var cursor: int
  var effects: Set[str]
  var receipts: Set[int]

  def bundleComplete(n: int): bool =
    if (n == 1) effects.contains("one-A") and effects.contains("one-B")
    else if (n == 2) true
    else if (n == 3) effects.contains("three-A")
    else false

  action init = all {
    ledgerHead' = 0,
    cursor' = 0,
    effects' = Set(),
    receipts' = Set(),
  }

  action persistLedger = all {
    ledgerHead < MAX,
    ledgerHead' = ledgerHead + 1,
    cursor' = cursor,
    effects' = effects,
    receipts' = receipts,
  }

  action effect = {
    nondet e = Set("one-A", "one-B", "three-A").oneOf()
    all {
      if (e == "three-A") ledgerHead >= 3 else ledgerHead >= 1,
      effects' = effects.union(Set(e)),
      ledgerHead' = ledgerHead,
      cursor' = cursor,
      receipts' = receipts,
    }
  }

  action durableReceipt = {
    nondet n = 1.to(MAX).oneOf()
    all {
      n <= ledgerHead,
      bundleComplete(n),
      receipts' = receipts.union(Set(n)),
      ledgerHead' = ledgerHead,
      cursor' = cursor,
      effects' = effects,
    }
  }

  action checkpoint = all {
    cursor < ledgerHead,
    receipts.contains(cursor + 1),
    bundleComplete(cursor + 1),
    cursor' = cursor + 1,
    ledgerHead' = ledgerHead,
    effects' = effects,
    receipts' = receipts,
  }

  action crashRestart = all {
    ledgerHead' = ledgerHead,
    cursor' = cursor,
    effects' = effects,
    receipts' = receipts,
  }

  action step = any { persistLedger, effect, durableReceipt, checkpoint, crashRestart }

  val prefixSafe = cursor <= ledgerHead and
    range(1, MAX + 1).forall(i =>
      (i <= cursor) implies (receipts.contains(i) and bundleComplete(i)))

  val effectsFromAccepted =
    effects.forall(e => if (e == "three-A") ledgerHead >= 3 else ledgerHead >= 1)

  val receiptsFromAccepted = receipts.forall(i => i >= 1 and i <= ledgerHead)

  val safety = prefixSafe and effectsFromAccepted and receiptsFromAccepted

  // Reachable midway through registration: it must NOT advance the cursor.
  val noPartialBundle = not(ledgerHead >= 1 and effects.contains("one-A")
    and not(effects.contains("one-B")) and cursor == 0)

  // No-effect event 2 needs a receipt even after event 1 has been processed.
  val noNoopReceipt = not(ledgerHead >= 2 and receipts.contains(2))
}
