// Negative control: illegal activation after a terminal commit.
// Timestamp presence alone cannot detect this bug: active trips may legally
// retain scheduled ends_at. The terminal-history bit detects resurrection.
module dispatch_terminal_bug {
  var status: str
  var endPresent: bool
  var terminalWritten: bool

  action init = all {
    status' = "COMPLETED",
    endPresent' = true,
    terminalWritten' = true,
  }

  action resurrect = all {
    status == "COMPLETED",
    status' = "ACTIVE",
    endPresent' = endPresent,
    terminalWritten' = terminalWritten,
  }

  action step = resurrect
  val safety = terminalWritten implies (status == "COMPLETED" or status == "CANCELLED")
}
