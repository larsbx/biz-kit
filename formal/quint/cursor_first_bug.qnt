// Negative control. This deliberately WRONG consumer acknowledges first
// and only later considers persisting its effect. Quint MUST find a safety
// violation. Never turn this into a production algorithm.

module cursor_first_bug {
  pure val MAX = 2

  var head: int
  var cursor: int
  var effects: Set[int]

  action init = all {
    head' = 0,
    cursor' = 0,
    effects' = Set(),
  }

  action append = all {
    head < MAX,
    head' = head + 1,
    cursor' = cursor,
    effects' = effects,
  }

  action unsafeCheckpoint = all {
    cursor < head,
    cursor' = cursor + 1,
    head' = head,
    effects' = effects,
  }

  action step = any { append, unsafeCheckpoint }

  val safety = cursor <= head and
    range(1, MAX + 1).forall(i => (i <= cursor) implies effects.contains(i))
}
