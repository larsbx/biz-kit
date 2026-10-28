// WRONG algorithm: marking an event processed after inserting only ONE of
// TWO required operational effects loses the second effect on restart.

module bundle_partial_bug {
  var ledgerHead: int
  var cursor: int
  var effects: Set[str]
  var receipts: bool

  action init = all {
    ledgerHead' = 0,
    cursor' = 0,
    effects' = Set(),
    receipts' = false,
  }

  action persistLedger = all {
    ledgerHead == 0,
    ledgerHead' = 1,
    cursor' = cursor,
    effects' = effects,
    receipts' = receipts,
  }

  action registerFirstOnly = all {
    ledgerHead == 1,
    effects' = effects.union(Set("A")),
    receipts' = receipts,
    ledgerHead' = ledgerHead,
    cursor' = cursor,
  }

  action unsafeCheckpoint = all {
    ledgerHead == 1,
    effects.contains("A"),
    cursor' = 1,
    receipts' = true,
    ledgerHead' = ledgerHead,
    effects' = effects,
  }

  action step = any { persistLedger, registerFirstOnly, unsafeCheckpoint }
  val safety = cursor == 0 or
    (receipts and effects.contains("A") and effects.contains("B"))
}
