// Negative control. This deliberately WRONG consumer acknowledges first
// and only later considers persisting its effect. Quint MUST find a safety
// violation. Never turn this into a production algorithm.

module cursor_first_bug {
  pure val MAX = 2

  var ledgerHead: int
  var cursor: int
  var effects: Set[int]

  action init = all {
    ledgerHead' = 0,
    cursor' = 0,
    effects' = Set(),
  }

  action persistLedger = all {
    ledgerHead < MAX,
    ledgerHead' = ledgerHead + 1,
    cursor' = cursor,
    effects' = effects,
  }

  action unsafeCheckpoint = all {
    cursor < ledgerHead,
    cursor' = cursor + 1,
    ledgerHead' = ledgerHead,
    effects' = effects,
  }

  action step = any { persistLedger, unsafeCheckpoint }

  val safety = cursor <= ledgerHead and
    1.to(MAX).forall(i => (i <= cursor) implies effects.contains(i))
}
