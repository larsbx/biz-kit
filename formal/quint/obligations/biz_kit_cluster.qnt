// biz_kit_cluster: "After partition recovery at most one fenced authority may
// perform effects".
//
// Rule modelled: BizKit.Cluster.Singleton (singleton.ex). Each node's keeper
// registers the module in :global; while partitioned each side may start its
// own instance. When the partition heals, :global calls resolve/3, which keeps
// the instance on the lower-named node and exits the other with
// {:global_name_conflict, module}. GUARDED is that conflict resolution.
// Abstracted: two nodes (0 < 1), one module, heal = name-table merge with
// resolution; an effect is issued only by a running instance. The model
// treats the conflict exit as atomic with the merge.
// FINDING: the code has no fencing token. The losing instance exits
// asynchronously after the merge, so an effect it issues in that window is
// not fenced, and both sides perform effects during the partition (split brain).
// The catalogue's "fenced" is therefore not established by the code.
module biz_kit_cluster_spec {
  const GUARDED: bool
  var running: Set[int]      // nodes hosting a running instance
  var partitioned: bool
  var recovered: bool        // at least one heal has happened
  var splitBrain: bool       // two instances ran at once during a partition

  action init = all { running' = Set(0), partitioned' = false, recovered' = false,
    splitBrain' = false }
  action partition = all { not(partitioned), partitioned' = true, running' = running,
    recovered' = recovered, splitBrain' = splitBrain }
  // A side with no reachable instance starts one (keeper race on :DOWN).
  action startOn(n: int): bool = all {
    not(running.contains(n)), partitioned or running.size() == 0,
    running' = running.union(Set(n)), partitioned' = partitioned, recovered' = recovered,
    splitBrain' = (splitBrain or running.size() == 1) }
  action heal = all { partitioned, partitioned' = false, recovered' = true,
    running' = if (GUARDED and running.size() > 1) Set(0) else running,
    splitBrain' = splitBrain }
  action crash(n: int): bool = all { running.contains(n), running' = running.exclude(Set(n)),
    partitioned' = partitioned, recovered' = recovered, splitBrain' = splitBrain }
  action step = any { partition, heal, nondet n = Set(0, 1).oneOf() any { startOn(n), crash(n) } }

  // Only a running instance performs effects, so after a heal at most one
  // instance may perform them at any instant.
  val obligation = (recovered and not(partitioned)) implies running.size() <= 1
  // Split brain during a partition, then a heal back to one instance.
  val obligationWitness = not(recovered and not(partitioned) and splitBrain and running.size() == 1)
}
module biz_kit_cluster { import biz_kit_cluster_spec(GUARDED = true).* }
module biz_kit_cluster_control { import biz_kit_cluster_spec(GUARDED = false).* }
