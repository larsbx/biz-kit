// spruce_goose: "After delegated cutover no secondary privileged direct writer
// can operate".
// Abstracts three gates: the irreversible authority row (migration
// 20260727191241, trigger enforce_irreversible_authority: only
// tuxedo -> ash with cutover_at set is allowed), SpruceGoose.Authority.require_tuxedo/0
// (ledger import refused once mode is not "tuxedo"), and
// SpruceGoose.AuthorityRuntime.ensure_local_execution_allowed/0 (direct CLI
// refused when the host marker names another authority host).
// ASSUMPTION / FINDING: ensure_local_execution_allowed/0 returns :ok when the
// marker file is missing ({:error, :enoent}), so it fails open; this model
// assumes the marker written at cutover stays present.
// Abstracted away: one rollback host; SQL and file I/O; the socket client.
// GUARDED switches off the trigger, require_tuxedo and the marker check.
module spruce_goose_spec {
  const GUARDED: bool

  var mode: str            // "tuxedo" | "ash"
  var delegated: bool      // host marker names the remote authority
  var cutOver: bool        // ghost: the cutover has happened
  var writesAfterCutover: int
  var refused: int

  action keep(m, d) = all {
    mode' = m, delegated' = d, cutOver' = cutOver,
    writesAfterCutover' = writesAfterCutover,
  }

  action init = all {
    mode' = "tuxedo", delegated' = false, cutOver' = false, writesAfterCutover' = 0, refused' = 0,
  }

  action cutover = all {
    mode == "tuxedo", not(cutOver),
    mode' = "ash", delegated' = true, cutOver' = true,
    writesAfterCutover' = writesAfterCutover, refused' = refused,
  }

  // An attempt to set mode back to tuxedo and clear the marker.
  action revert = all {
    cutOver,
    if (GUARDED) all { keep(mode, delegated), refused' = refused + 1 }
    else all { keep("tuxedo", false), refused' = refused },
  }

  // Legacy ledger import (require_tuxedo) or a direct CLI write (marker check).
  action secondaryWrite(viaImport) = {
    val allowed = if (viaImport) mode == "tuxedo" else not(delegated)
    if (allowed or not(GUARDED)) all {
      mode' = mode, delegated' = delegated, cutOver' = cutOver, refused' = refused,
      writesAfterCutover' = writesAfterCutover + (if (cutOver) 1 else 0),
    } else all { keep(mode, delegated), refused' = refused + 1 }
  }

  action step = any { cutover, revert, nondet i = Set(true, false).oneOf() secondaryWrite(i) }

  // Once cut over, no secondary direct writer has written.
  val obligation = writesAfterCutover == 0
  // The cutover happened and a secondary write or a revert was then refused.
  val obligationWitness = not(cutOver and refused > 0)
}

module spruce_goose { import spruce_goose_spec(GUARDED = true).* }
module spruce_goose_control { import spruce_goose_spec(GUARDED = false).* }
