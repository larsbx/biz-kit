// One change-feed subscriber against the ledger appender
// (docs/architecture/2026-10-18-change-feed.md; CoopSubstrate.Feed).
//
// Log.append/2 persists a batch, then notifies registered subscribers, in one
// handle_call; a subscriber can register between those two steps. Event n is
// the n-th ledger event (its global_seq). The subscriber delivers the events
// it has folded; `delivered` is what its client has seen.
//
//   ./check.sh change_feed.qnt
module change_feed {
  pure val MAX = 4

  var persisted: int        // events 1..persisted are durable in the store
  var unnotified: List[int] // persisted, notification not yet sent
  var registered: bool
  var mailbox: List[int]
  var phase: str            // "start" | "reading" | "live"
  var delivered: List[int]
  var order: str            // "registerFirst" (Feed.open) or "readFirst"
  var dropped: bool         // a notification was lost (Log died before notifying)

  def lastSeq(l: List[int]): int = if (l.length() == 0) 0 else l[l.length() - 1]
  val last = lastSeq(delivered)

  // Fold the store from last + 1 through n (Feed.backfill). Ranges over the
  // constant 1..MAX, as Apalache requires.
  def upTo(n: int): List[int] =
    range(1, MAX + 1).foldl(delivered, (acc, i) => if (i > lastSeq(acc) and i <= n) acc.append(i) else acc)

  action init = all {
    persisted' = 0,
    unnotified' = [],
    registered' = false,
    mailbox' = [],
    phase' = "start",
    delivered' = [],
    nondet o = Set("registerFirst", "readFirst").oneOf()
    order' = o,
    dropped' = false,
  }

  action persist = all {
    persisted < MAX,
    persisted' = persisted + 1,
    unnotified' = unnotified.append(persisted + 1),
    registered' = registered, mailbox' = mailbox, phase' = phase,
    delivered' = delivered, order' = order, dropped' = dropped,
  }

  // The second half of Log's handle_call: send to every registered subscriber.
  action notify = all {
    unnotified.length() > 0,
    unnotified' = unnotified.tail(),
    mailbox' = if (registered) mailbox.append(unnotified.head()) else mailbox,
    persisted' = persisted, registered' = registered, phase' = phase,
    delivered' = delivered, order' = order, dropped' = dropped,
  }

  // The appender died after persisting, before notifying.
  action drop = all {
    unnotified.length() > 0,
    unnotified' = unnotified.tail(),
    dropped' = true,
    persisted' = persisted, registered' = registered, mailbox' = mailbox, phase' = phase,
    delivered' = delivered, order' = order,
  }

  action register = all {
    not(registered),
    (order == "registerFirst" and phase == "start") or (order == "readFirst" and phase == "live"),
    registered' = true,
    phase' = if (phase == "start") "reading" else phase,
    persisted' = persisted, unnotified' = unnotified, mailbox' = mailbox,
    delivered' = delivered, order' = order, dropped' = dropped,
  }

  action startReading = all {
    order == "readFirst",
    phase == "start",
    phase' = "reading",
    persisted' = persisted, unnotified' = unnotified, registered' = registered,
    mailbox' = mailbox, delivered' = delivered, order' = order, dropped' = dropped,
  }

  // Catch-up reads the store page by page until a page comes back short.
  action readStep = all {
    phase == "reading",
    if (last < persisted) all { delivered' = delivered.append(last + 1), phase' = phase }
    else all { delivered' = delivered, phase' = "live" },
    persisted' = persisted, unnotified' = unnotified, registered' = registered,
    mailbox' = mailbox, order' = order, dropped' = dropped,
  }

  // Feed.advance/2: drop what is already delivered, take the next event,
  // backfill from the store on a gap.
  action consume = all {
    phase == "live",
    mailbox.length() > 0,
    val m = mailbox.head()
    delivered' = if (m <= last) delivered else if (m == last + 1) delivered.append(m) else upTo(persisted),
    mailbox' = mailbox.tail(),
    persisted' = persisted, unnotified' = unnotified, registered' = registered,
    phase' = phase, order' = order, dropped' = dropped,
  }

  // Feed.tick/1 on the heartbeat: backfill to the appender's head.
  action tick = all {
    phase == "live",
    delivered' = upTo(persisted),
    persisted' = persisted, unnotified' = unnotified, registered' = registered,
    mailbox' = mailbox, phase' = phase, order' = order, dropped' = dropped,
  }

  action step = any { persist, notify, drop, register, startReading, readStep, consume, tick }

  // -- properties ----------------------------------------------------------------

  val quiescent = phase == "live" and unnotified.length() == 0 and mailbox.length() == 0
  val complete = last == persisted

  // Every event at most once, in ledger order, without gaps.
  val inOrder = delivered.indices().forall(i => delivered[i] == i + 1)
  val withinStore = last <= persisted
  // Registering before reading loses nothing: once the notifications drain, the
  // client has every persisted event.
  val lossless = (order == "registerFirst" and not(dropped) and quiescent) implies complete

  val safety = inOrder and withinStore and lossless

  // Witnesses: each must be violated, i.e. the state is reachable.
  // Reading first loses an event for good, though no notification was dropped.
  val noLossReadingFirst = not(order == "readFirst" and not(dropped) and quiescent and not(complete))
  // A dropped notification leaves the client behind until a tick.
  val noLossAfterDrop = not(order == "registerFirst" and dropped and quiescent and not(complete))
  // Catch-up and notifications overlap, so deduplication is exercised.
  val noOverlap = not(phase == "live" and mailbox.length() > 0 and mailbox.head() <= last)
  // A gap reaches the consumer, so backfill is exercised.
  val noGap = not(phase == "live" and mailbox.length() > 0 and mailbox.head() > last + 1)
}
