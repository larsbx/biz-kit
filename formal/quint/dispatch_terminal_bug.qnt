// Negative control: an illegal activation of a completed trip leaves ends_at
// set, reproducing PR #202's resurrection hazard. This MUST violate safety.
module dispatch_terminal_bug {
  var status: str
  var ended: bool

  action init = all {
    status' = "COMPLETED",
    ended' = true,
  }

  action resurrect = all {
    status == "COMPLETED",
    status' = "ACTIVE",
    ended' = ended,
  }

  action step = resurrect
  val safety = status == "ACTIVE" implies not(ended)
}
