// EventStore consumer: accepted ledger prefix -> durable operational effect
// registration -> cursor acknowledgment. Finite abstraction MAX=3.
// Wakeups can be lost or duplicated and do not carry business authority.
//
// Safety is unconditional; eventual progress requires an additional
// scheduling/fairness assumption not included in this model.

module event_cursor {
  pure val MAX = 3

  var head: int                // durable signed ledger length
  var cursor: int              // exclusive acknowledged prefix (0..head)
  var effects: Set[int]        // durable derived effect IDs, event numbers 1..head
  var notifications: int       // unreliable wakeup count (not authority)
  var previousCursor: int

  action init = all {
    head' = 0,
    cursor' = 0,
    effects' = Set(),
    notifications' = 0,
    previousCursor' = 0,
  }

  // Append is the only way to change the canonical ledger length.
  action append = all {
    head < MAX,
    head' = head + 1,
    cursor' = cursor,
    effects' = effects,
    notifications' = notifications,
    previousCursor' = cursor,
  }

  // Register any accepted event; retries use set union, not an extra effect.
  action register = {
    nondet n = 1.to(MAX).oneOf()
    all {
      n <= head,
      effects' = effects.union(Set(n)),
      head' = head,
      cursor' = cursor,
      notifications' = notifications,
      previousCursor' = cursor,
    }
  }

  // Commit the durable checkpoint only AFTER the next effect is registered.
  action checkpoint = all {
    cursor < head,
    effects.contains(cursor + 1),
    cursor' = cursor + 1,
    head' = head,
    effects' = effects,
    notifications' = notifications,
    previousCursor' = cursor,
  }

  action wake = all {
    notifications < MAX,
    notifications' = notifications + 1,
    head' = head,
    cursor' = cursor,
    effects' = effects,
    previousCursor' = cursor,
  }

  // Messages may disappear; cursor and effects are durable and unaffected.
  action drop = all {
    notifications > 0,
    notifications' = notifications - 1,
    head' = head,
    cursor' = cursor,
    effects' = effects,
    previousCursor' = cursor,
  }

  // Restart drops all ephemeral notifications. Replaying read cursor+1
  // still discovers the committed signed ledger records.
  action crashRestart = all {
    notifications' = 0,
    head' = head,
    cursor' = cursor,
    effects' = effects,
    previousCursor' = cursor,
  }

  action step = any { append, register, checkpoint, wake, drop, crashRestart }

  val cursorWithinHead = cursor >= 0 and cursor <= head
  val registeredOnlyAfterAppend = effects.forall(i => i > 0 and i <= head)

  // Every prefix position has been committed, no gap and no skip.
  val noPrematureCheckpoint =
    range(1, MAX + 1).forall(i => (i <= cursor) implies effects.contains(i))

  val cursorNeverBacktracks = cursor >= previousCursor
  val safety =
    cursorWithinHead and registeredOnlyAfterAppend
    and noPrematureCheckpoint and cursorNeverBacktracks

  // Reachability witnesses: out-of-order effect registration and
  // staged-before-ack states are deliberately allowed.
  val noOutOfOrderEffect = not(
    head >= 2 and effects.contains(2) and not(effects.contains(1)))
  val noStagedButNotAcknowledged = not(
    head >= 1 and effects.contains(1) and cursor == 0)
}
