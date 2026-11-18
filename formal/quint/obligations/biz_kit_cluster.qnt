// biz_kit_cluster: "After partition recovery at most one fenced authority may
// perform effects".
//
// Rule modelled: the effects that carry authority are ledger appends, and the
// fence is at the durable sink, not in the process registry.
// BizKit.Cluster.Singleton lets each side of a partition start its own
// CoopSubstrate.Log, and after a heal :global keeps one (resolve/3). Every
// append passes the appender's head (head.global_seq) as expected_version to
// CoopSubstrate.EventStore.append_to_stream/3 (Log.persist/2), so the store
// admits one append per position; a stale appender gets
// :wrong_expected_version and stops with :ledger_moved, restarting from the
// store. GUARDED is that expected-version check. Tested by
// CoopSubstrate.ClusterTest "a second appender cannot fork the ledger".
// Not modelled, and not fenced: other singletons' in-memory state (sessions,
// nonces, held commands, enrolments, quota) diverges per side during a
// partition and the losing side's is dropped at the heal
// (docs/architecture/2026-10-19-cluster.md, "Partitions are resolved by OTP").
// Abstracted: two appenders (nodes 0, 1), a ledger of up to 3 positions,
// partition and heal; an appender's head is the ledger length it last read.
module biz_kit_cluster_spec {
  const GUARDED: bool
  val Nodes = Set(0, 1)
  var ledger: List[int]          // the appender that wrote each position
  var running: Set[int]          // nodes hosting a running appender
  var seen: int -> int           // each appender's view of the ledger length
  var partitioned: bool
  var refused: bool              // a stale append was refused at least once
  var accepted: Set[(int, int)]  // ghost: every (position, appender) ever stored

  action init = all {
    ledger' = List(), running' = Set(0), seen' = Nodes.mapBy(_ => 0),
    partitioned' = false, refused' = false, accepted' = Set(),
  }

  action keep(l, r, h, p, x) = all {
    ledger' = l, running' = r, seen' = h, partitioned' = p, refused' = x,
    accepted' = accepted,
  }

  action partition = all { not(partitioned), keep(ledger, running, seen, true, refused) }

  // A side with no reachable appender starts one, reading the store.
  action start(n: int): bool = all {
    not(running.contains(n)), partitioned or running.size() == 0,
    keep(ledger, running.union(Set(n)), seen.set(n, ledger.length()), partitioned, refused),
  }

  // :global keeps the lower-named node's appender.
  action heal = all {
    partitioned,
    keep(ledger, if (running.size() > 1) Set(0) else running, seen, false, refused),
  }

  // An append at the appender's head: the store refuses it when the head is
  // stale (GUARDED); the stale appender then restarts from the store.
  action write(n: int): bool = all {
    running.contains(n), ledger.length() < 3,
    if (not(GUARDED) or seen.get(n) == ledger.length()) {
      // Unguarded, a stale appender writes at its own head, over the others.
      val l = ledger.slice(0, seen.get(n)).append(n)
      all {
        ledger' = l, running' = running, seen' = seen.set(n, l.length()),
        partitioned' = partitioned, refused' = refused,
        accepted' = accepted.union(Set((seen.get(n), n))),
      }
    } else
      keep(ledger, running, seen.set(n, ledger.length()), partitioned, true),
  }

  action step = any {
    partition, heal,
    nondet n = Nodes.oneOf()
    any { start(n), write(n) },
  }

  // The ledger is one linear chain: no position was ever accepted from two
  // appenders, so a stale (partitioned or losing) appender never overwrote
  // an effect, during the partition or after it healed.
  val obligation = accepted.forall(a => accepted.forall(b => a._1 == b._1 implies a == b))
  // Two appenders ran, a stale append was refused, and the ledger still grew.
  val obligationWitness = not(refused and ledger.length() >= 2 and
    accepted.exists(a => a._2 == 1))
}
module biz_kit_cluster { import biz_kit_cluster_spec(GUARDED = true).* }
module biz_kit_cluster_control { import biz_kit_cluster_spec(GUARDED = false).* }
