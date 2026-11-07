// eatsbot: "Retirement preserves accepted order/delivery history without a
// competing writer".
//
// Formalized as the R5/R6 rule of docs/architecture/2026-10-28-eatsbot-salvage-
// and-retirement-plan.md: before cutover only the legacy Eatsbot writer accepts
// order/delivery facts; cutover migrates the accepted legacy history to the
// platform writer and stops legacy writes; retirement archives, never deletes.
// Obligation: from cutover on, every accepted legacy fact is in the migrated
// history (none lost, no legacy write after cutover) and retirement keeps it.
// GUARDED is the stop of legacy writes at cutover.
// Abstracted: history as counters of accepted facts per writer.
// FINDING: no such fence exists in code. apps/eatsbot (Eatsbot.Application)
// starts the legacy Ash writer unconditionally; R5 is unimplemented, so this
// models the planned rule, not enforced behaviour.
module eatsbot_spec {
  const GUARDED: bool
  var phase: str          // "LEGACY" | "CUTOVER" | "RETIRED"
  var legacyAccepted: int // facts accepted by the legacy writer
  var migrated: int       // legacy facts carried into the platform history
  var platformAccepted: int
  var archived: bool

  action init = all { phase' = "LEGACY", legacyAccepted' = 0, migrated' = 0,
    platformAccepted' = 0, archived' = false }
  action legacyWrite = all { phase != "RETIRED",
    phase == "LEGACY" or not(GUARDED),
    legacyAccepted' = legacyAccepted + 1, phase' = phase, migrated' = migrated,
    platformAccepted' = platformAccepted, archived' = archived }
  action cutover = all { phase == "LEGACY", phase' = "CUTOVER", migrated' = legacyAccepted,
    legacyAccepted' = legacyAccepted, platformAccepted' = platformAccepted, archived' = archived }
  action platformWrite = all { phase != "LEGACY",
    platformAccepted' = platformAccepted + 1, phase' = phase, legacyAccepted' = legacyAccepted,
    migrated' = migrated, archived' = archived }
  action retire = all { phase == "CUTOVER", phase' = "RETIRED", archived' = true,
    legacyAccepted' = legacyAccepted, migrated' = migrated, platformAccepted' = platformAccepted }
  action step = any { legacyWrite, cutover, platformWrite, retire }

  val obligation = phase != "LEGACY" implies migrated == legacyAccepted
  val obligationWitness = not(phase == "RETIRED" and archived and migrated > 0 and platformAccepted > 0)
}
module eatsbot { import eatsbot_spec(GUARDED = true).* }
module eatsbot_control { import eatsbot_spec(GUARDED = false).* }
