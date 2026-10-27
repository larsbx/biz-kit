// WRONG algorithm: marking an event processed after inserting only ONE of
// TWO required operational effects loses the second effect on restart.

module bundle_partial_bug {
  var head: int
  var cursor: int
  var effects: Set[str]
  var receipts: bool

  action init = all {
    head' = 0,
    cursor' = 0,
    effects' = Set(),
    receipts' = false,
  }

  action append = all {
    head == 0,
    head' = 1,
    cursor' = cursor,
    effects' = effects,
    receipts' = receipts,
  }

  action registerFirstOnly = all {
    head == 1,
    effects' = effects.union(Set("A")),
    receipts' = receipts,
    head' = head,
    cursor' = cursor,
  }

  action unsafeCheckpoint = all {
    head == 1,
    effects.contains("A"),
    cursor' = 1,
    receipts' = true,
    head' = head,
    effects' = effects,
  }

  action step = any { append, registerFirstOnly, unsafeCheckpoint }
  val safety = cursor == 0 or
    (receipts and effects.contains("A") and effects.contains("B"))
}
