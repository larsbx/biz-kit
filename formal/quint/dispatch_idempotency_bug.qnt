// Negative control: body-only hashing permits one idempotency key to replay
// load A's response on load B. MUST produce a safety violation.
module dispatch_idempotency_bug {
  var claimed: bool
  var savedTarget: str
  var lastReplayTarget: str
  var replied: bool

  action init = all {
    claimed' = false,
    savedTarget' = "",
    lastReplayTarget' = "",
    replied' = false,
  }

  action first = all {
    not(claimed),
    claimed' = true,
    savedTarget' = "loadA",
    lastReplayTarget' = lastReplayTarget,
    replied' = replied,
  }

  // Same body/key, different target: a body-only implementation replays.
  action wrongReplay = all {
    claimed,
    savedTarget == "loadA",
    claimed' = claimed,
    savedTarget' = savedTarget,
    lastReplayTarget' = "loadB",
    replied' = true,
  }

  action step = any { first, wrongReplay }
  val safety = replied implies lastReplayTarget == savedTarget
}
