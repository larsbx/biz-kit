// Finite Dispatch lifecycle refinement: one organization-owned assignment.
// Successful moves atomically update status, version, end marker and audit count.
// Unauthorized/stale/invalid requests are represented as rejected stuttering
// attempts, never as state mutations. Actual SQL transaction isolation is a
// separate integration obligation.
module dispatch_trip {
  var status: str
  var version: int
  var ended: bool
  var auditCount: int
  var refusals: int

  action init = all {
    status' = "PLANNED",
    version' = 0,
    ended' = false,
    auditCount' = 0,
    refusals' = 0,
  }

  action activate = all {
    status == "PLANNED",
    status' = "ACTIVE",
    version' = version + 1,
    ended' = false,
    auditCount' = auditCount + 1,
    refusals' = refusals,
  }

  action complete = all {
    status == "ACTIVE",
    status' = "COMPLETED",
    version' = version + 1,
    ended' = true,
    auditCount' = auditCount + 1,
    refusals' = refusals,
  }

  action cancel = all {
    status == "PLANNED" or status == "ACTIVE",
    status' = "CANCELLED",
    version' = version + 1,
    ended' = true,
    auditCount' = auditCount + 1,
    refusals' = refusals,
  }

  action reject = all {
    status' = status,
    version' = version,
    ended' = ended,
    auditCount' = auditCount,
    refusals' = refusals + 1,
  }

  action restart = all {
    status' = status,
    version' = version,
    ended' = ended,
    auditCount' = auditCount,
    refusals' = refusals,
  }

  action step = any { activate, complete, cancel, reject, restart }

  val safety =
    auditCount == version and
    (status == "PLANNED" implies (version == 0 and not(ended))) and
    (status == "ACTIVE" implies (version == 1 and not(ended))) and
    (status == "COMPLETED" implies (version == 2 and ended)) and
    (status == "CANCELLED" implies (ended and (version == 1 or version == 2))) and
    (ended implies (status == "COMPLETED" or status == "CANCELLED"))

  // Require traces to both terminal statuses and to a rejected request.
  val noCompletedWitness = not(status == "COMPLETED")
  val noCancelledWitness = not(status == "CANCELLED")
  val noRefusalWitness = not(refusals > 0)
}
