// One organization-owned assignment, with or without a scheduled ends_at.
// endPresent abstracts ends_at != nil; it does NOT mean the trip has terminated.
// terminalWritten is ghost history: a complete/cancel commit has occurred.
// Rejected attempts stutter; actual SQL isolation remains an integration obligation.
module dispatch_trip {
  var status: str
  var version: int
  var endPresent: bool
  var scheduledEndPresent: bool
  var terminalWritten: bool
  var auditCount: int
  var refusals: int

  action init = {
    nondet scheduled = Set(false, true).oneOf()
    all {
      status' = "PLANNED",
      version' = 0,
      endPresent' = scheduled,
      scheduledEndPresent' = scheduled,
      terminalWritten' = false,
      auditCount' = 0,
      refusals' = 0,
    }
  }

  action activate = all {
    status == "PLANNED",
    status' = "ACTIVE",
    version' = version + 1,
    endPresent' = endPresent,
    scheduledEndPresent' = scheduledEndPresent,
    terminalWritten' = terminalWritten,
    auditCount' = auditCount + 1,
    refusals' = refusals,
  }

  action complete = all {
    status == "ACTIVE",
    status' = "COMPLETED",
    version' = version + 1,
    endPresent' = true,
    scheduledEndPresent' = scheduledEndPresent,
    terminalWritten' = true,
    auditCount' = auditCount + 1,
    refusals' = refusals,
  }

  action cancel = all {
    status == "PLANNED" or status == "ACTIVE",
    status' = "CANCELLED",
    version' = version + 1,
    endPresent' = true,
    scheduledEndPresent' = scheduledEndPresent,
    terminalWritten' = true,
    auditCount' = auditCount + 1,
    refusals' = refusals,
  }

  action reject = all {
    status' = status,
    version' = version,
    endPresent' = endPresent,
    scheduledEndPresent' = scheduledEndPresent,
    terminalWritten' = terminalWritten,
    auditCount' = auditCount,
    refusals' = refusals + 1,
  }

  action restart = all {
    status' = status,
    version' = version,
    endPresent' = endPresent,
    scheduledEndPresent' = scheduledEndPresent,
    terminalWritten' = terminalWritten,
    auditCount' = auditCount,
    refusals' = refusals,
  }

  action step = any { activate, complete, cancel, reject, restart }

  val safety =
    auditCount == version and
    (status == "PLANNED" implies (version == 0 and not(terminalWritten) and endPresent == scheduledEndPresent)) and
    (status == "ACTIVE" implies (version == 1 and not(terminalWritten) and endPresent == scheduledEndPresent)) and
    (status == "COMPLETED" implies (version == 2 and terminalWritten and endPresent)) and
    (status == "CANCELLED" implies (terminalWritten and endPresent and (version == 1 or version == 2))) and
    (terminalWritten implies (status == "COMPLETED" or status == "CANCELLED"))

  val noCompletedWitness = not(status == "COMPLETED")
  val noCancelledWitness = not(status == "CANCELLED")
  val noRefusalWitness = not(refusals > 0)
  val noScheduledActiveWitness = not(status == "ACTIVE" and scheduledEndPresent and endPresent)
  val noUnscheduledActiveWitness = not(status == "ACTIVE" and not(scheduledEndPresent) and not(endPresent))
}
