// Obligation (federation_service): stale or withdrawn listings cannot be
// resurrected through reordering or retry.
//
// Rule in code: FederationService.Store project/5 and project_metadata/4. A
// pending inbox item is applied at most once (status != :pending refuses); a
// delete always projects a tombstone (withdrawn: true); any later update
// against a withdrawn row is refused (:withdrawn); an update whose revision
// is <= the stored revision is refused (:stale_revision). Delivery order is
// arbitrary (Inbox.drain/2 retries deferred items).
// Abstracted: one listing, owner substitution and moderation omitted;
// revisions 1..3; the inbox is a set delivered in any order, with retries.
module federation_service_spec {
  const GUARDED: bool
  val UPDATES = 1.to(3)
  var withdrawn: bool
  var revision: int          // 0: no row yet
  var deleteApplied: bool    // ghost
  var maxApplied: int        // ghost: highest revision ever projected

  action init = all { withdrawn' = false, revision' = 0, deleteApplied' = false, maxApplied' = 0 }
  action update = {
    nondet r = UPDATES.oneOf()
    all {
      not(GUARDED) or (not(withdrawn) and r > revision),
      withdrawn' = false, revision' = r, deleteApplied' = deleteApplied,
      maxApplied' = if (r > maxApplied) r else maxApplied,
    }
  }
  action delete = all { withdrawn' = true, revision' = revision, deleteApplied' = true,
    maxApplied' = maxApplied }
  action stutter = all { withdrawn' = withdrawn, revision' = revision,
    deleteApplied' = deleteApplied, maxApplied' = maxApplied }
  action step = any { update, delete, stutter }

  val obligation = all {
    deleteApplied implies withdrawn,
    not(withdrawn) implies revision == maxApplied,
  }
  val obligationWitness = not(deleteApplied and maxApplied >= 2)
}
module federation_service { import federation_service_spec(GUARDED = true).* }
module federation_service_control { import federation_service_spec(GUARDED = false).* }
