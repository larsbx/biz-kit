// biz_kit_extension: "Extension discovery and inert planning cannot grant
// permission, invoke an extension or mutate authoritative state."
// Abstracts BizKit.Extension.Catalog.build/1 (validates host-supplied manifests
// via BizKit.Extension.Manifest.validate/1, which only *records*
// requested_grants), Catalog.activation_plan/2 (returns a filtered list of
// catalog entries; unapproved dependency -> {:unapproved_dependency, id}) and
// BizKit.Extension.Registry (toggles read-only visibility only).
// The code has no grant, invocation or business-write path at all, so the
// guard here is the absence of those effects: GUARDED = false switches on a
// hypothetical planner that applies requested_grants, starts the extension
// and writes state when it plans. Abstracted away: two extensions, x needing y;
// manifest shape validation; descriptor contents.
module biz_kit_extension_spec {
  const GUARDED: bool
  val EXTS = Set("x", "y")

  var visible: Set[str]   // Registry visibility
  var grants: int         // authoritative permission grants
  var invocations: int    // extension callbacks run after startup
  var writes: int         // authoritative business-state mutations
  var refusedPlans: int

  action init = all { visible' = Set(), grants' = 0, invocations' = 0, writes' = 0, refusedPlans' = 0 }

  // activation_plan(catalog, approved) then Registry reconciliation.
  action plan(approved) = {
    val ok = approved.contains("x") implies approved.contains("y")
    all {
      if (ok) all {
        visible' = approved, refusedPlans' = refusedPlans,
        grants' = if (GUARDED) grants else grants + 1,
        invocations' = if (GUARDED) invocations else invocations + 1,
        writes' = if (GUARDED) writes else writes + 1,
      } else all {
        visible' = visible, refusedPlans' = refusedPlans + 1,
        grants' = grants, invocations' = invocations, writes' = writes,
      },
    }
  }

  action step = nondet a = EXTS.powerset().oneOf() plan(a)

  // Discovery and planning leave grants, invocations and authoritative state untouched.
  val obligation = grants == 0 and invocations == 0 and writes == 0
  // An extension that declares a dependency became visible, after an
  // unapproved-dependency plan was refused.
  val obligationWitness = not(visible.contains("x") and refusedPlans > 0)
}

module biz_kit_extension { import biz_kit_extension_spec(GUARDED = true).* }
module biz_kit_extension_control { import biz_kit_extension_spec(GUARDED = false).* }
