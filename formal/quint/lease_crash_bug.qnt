// WRONG implementation: an in-flight agent effect is forgotten after crash.
// Restart resets a durable lease and launches the same effect a second time.
// The negative control MUST exhibit launchCount > 1.

module lease_crash_bug {
  var holder: bool
  var launched: bool
  var launchCount: int

  action init = all {
    holder' = false,
    launched' = false,
    launchCount' = 0,
  }

  action claim = all {
    not(holder),
    holder' = true,
    launched' = launched,
    launchCount' = launchCount,
  }

  action launch = all {
    holder,
    not(launched),
    launched' = true,
    launchCount' = launchCount + 1,
    holder' = holder,
  }

  action unsafeRestart = all {
    holder,
    holder' = false,
    launched' = false,
    launchCount' = launchCount,
  }

  action step = any { claim, launch, unsafeRestart }
  val safety = launchCount <= 1
}
