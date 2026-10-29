// Abstract refinement target for one atomic PostgreSQL effect-bundle+cursor
// transaction. Event 1 requires TWO effects; event 2 requires zero effects
// but still requires a durable processed receipt. No external agent launch.
//
// Pending/staged writes are volatile and rolled back on transaction abort.
// A commit updates durable effects, receipt, and cursor in the same action.
// Postgres must implement this with a single SQL transaction and row CAS.
// This small model does not prove the eventual production database code.

module cursor_transaction {
  pure val MAX = 2

  var ledgerHead: int
  var cursor: int
  var effects: Set[str]
  var receipts: Set[int]

  var inTx: bool
  var staged: Set[str]
  var notifications: int

  action init = all {
    ledgerHead' = 0,
    cursor' = 0,
    effects' = Set(),
    receipts' = Set(),
    inTx' = false,
    staged' = Set(),
    notifications' = 0,
  }

  // Canonical ledger persistLedger. Never modifies the consumer's durable state.
  action persistLedger = all {
    ledgerHead < MAX,
    ledgerHead' = ledgerHead + 1,
    cursor' = cursor,
    effects' = effects,
    receipts' = receipts,
    inTx' = inTx,
    staged' = staged,
    notifications' = notifications,
  }

  action begin = all {
    cursor < ledgerHead,
    not(inTx),
    inTx' = true,
    staged' = Set(),
    ledgerHead' = ledgerHead,
    cursor' = cursor,
    effects' = effects,
    receipts' = receipts,
    notifications' = notifications,
  }

  action stageEffect = {
    nondet effect = Set("A", "B").oneOf()
    all {
      inTx,
      cursor == 0,
      staged' = staged.union(Set(effect)),
      ledgerHead' = ledgerHead,
      cursor' = cursor,
      effects' = effects,
      receipts' = receipts,
      inTx' = inTx,
      notifications' = notifications,
    }
  }

  // One indivisible transaction commit. A partial event-1 effect bundle
  // cannot advance; event 2 advances on its processed-no-op receipt alone.
  action commit = all {
    inTx,
    cursor < ledgerHead,
    if (cursor == 0) staged.contains("A") and staged.contains("B")
    else true,
    cursor' = cursor + 1,
    effects' = effects.union(staged),
    receipts' = receipts.union(Set(cursor + 1)),
    inTx' = false,
    staged' = Set(),
    ledgerHead' = ledgerHead,
    notifications' = notifications,
  }

  action crashRollback = all {
    inTx' = false,
    staged' = Set(),
    cursor' = cursor,
    effects' = effects,
    receipts' = receipts,
    ledgerHead' = ledgerHead,
    notifications' = 0,
  }

  action notify = all {
    notifications < MAX,
    notifications' = notifications + 1,
    ledgerHead' = ledgerHead,
    cursor' = cursor,
    effects' = effects,
    receipts' = receipts,
    inTx' = inTx,
    staged' = staged,
  }

  action step = any { persistLedger, begin, stageEffect, commit, crashRollback, notify }

  val prefixSafe = cursor >= 0 and cursor <= ledgerHead
    and (cursor < 1 or
      (effects.contains("A") and effects.contains("B") and receipts.contains(1)))
    and (cursor < 2 or receipts.contains(2))

  // Volatile staging may contain only part of the bundle; committed state
  // can NEVER expose just one effect, even if the process dies mid-stage.
  val noLeakedPartialEffects =
    (effects.contains("A") == effects.contains("B"))
    and (effects.contains("A") implies cursor >= 1)
  val receiptsFromLedger = receipts.forall(i => i >= 1 and i <= ledgerHead)
  val safety = prefixSafe and noLeakedPartialEffects and receiptsFromLedger

  // Observe an uncommitted, partial registration that must be rolled back.
  val noPartialTxWitness = not(inTx and staged.contains("A")
    and not(staged.contains("B")) and cursor == 0)

  // Observe successful full commit and a separately committed no-op event.
  val noFullCommitWitness = not(cursor == 1 and receipts.contains(1))
  val noNoopCommitWitness = not(cursor == 2 and receipts.contains(2))
}
