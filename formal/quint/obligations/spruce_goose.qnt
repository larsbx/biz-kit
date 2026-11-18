// spruce_goose: "After delegated cutover no secondary privileged direct writer
// can operate".
// Abstracts three gates: the irreversible authority row (migration
// 20260727191241, trigger enforce_irreversible_authority: only
// tuxedo -> ash with cutover_at set is allowed), SpruceGoose.Authority.require_tuxedo/0
// (ledger import refused once mode is not "tuxedo"), and
// SpruceGoose.AuthorityRuntime.ensure_local_execution_allowed/0 (direct CLI
// allowed only when the host marker reads `local`; a missing, empty or
// remote marker refuses, so losing the marker after cutover cannot reopen
// direct writes; tested by SpruceGoose.AuthorityRuntimeTest).
// Abstracted away: one rollback host; SQL and file I/O; the socket client.
// GUARDED switches off the trigger, require_tuxedo and the marker check.
module spruce_goose_spec {
  const GUARDED: bool

  var mode: str            // "tuxedo" | "ash"
  var marker: str          // "local" | "remote" | "absent" (the host marker file)
  var cutOver: bool        // ghost: the cutover has happened
  var writesAfterCutover: int
  var refused: int

  action keep(m, k) = all {
    mode' = m, marker' = k, cutOver' = cutOver,
    writesAfterCutover' = writesAfterCutover,
  }

  action init = all {
    mode' = "tuxedo", marker' = "local", cutOver' = false, writesAfterCutover' = 0, refused' = 0,
  }

  action cutover = all {
    mode == "tuxedo", not(cutOver),
    mode' = "ash", marker' = "remote", cutOver' = true,
    writesAfterCutover' = writesAfterCutover, refused' = refused,
  }

  // An attempt to set mode back to tuxedo and clear the marker.
  action revert = all {
    cutOver,
    if (GUARDED) all { keep(mode, marker), refused' = refused + 1 }
    else all { keep("tuxedo", "local"), refused' = refused },
  }

  // The marker file is deleted or never restored (a rebuilt host, a cleaned home).
  action loseMarker = all { keep(mode, "absent"), refused' = refused }

  // Legacy ledger import (require_tuxedo) or a direct CLI write (marker check).
  action secondaryWrite(viaImport) = {
    val allowed = if (viaImport) mode == "tuxedo" else marker == "local"
    if (allowed or not(GUARDED)) all {
      mode' = mode, marker' = marker, cutOver' = cutOver, refused' = refused,
      writesAfterCutover' = writesAfterCutover + (if (cutOver) 1 else 0),
    } else all { keep(mode, marker), refused' = refused + 1 }
  }

  action step = any { cutover, revert, loseMarker, nondet i = Set(true, false).oneOf() secondaryWrite(i) }

  // Once cut over, no secondary direct writer has written.
  val obligation = writesAfterCutover == 0
  // The cutover happened and a secondary write or a revert was then refused.
  val obligationWitness = not(cutOver and refused > 0)
}

module spruce_goose { import spruce_goose_spec(GUARDED = true).* }
module spruce_goose_control { import spruce_goose_spec(GUARDED = false).* }
