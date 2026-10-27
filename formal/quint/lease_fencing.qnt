// Agent-neutral lease model, one signed effect ID, two competing workers.
// The CAS predicate is the trusted PostgreSQL row_version/holder check.
// A crash does NOT release a lease or license an external relaunch.
// Real backend effect lookup/verified absence is NOT modeled here.

module lease_fencing {
  pure val WORKERS = Set("workerA", "workerB")

  var version: int
  var epoch: int
  var holder: str                // "none" or a claimed worker
  var cancelled: bool
  var launched: bool             // external effect was dispatched
  var launchCount: int           // non-idempotent launches (negative control)
  var previousEpoch: int

  action init = all {
    version' = 0,
    epoch' = 0,
    holder' = "none",
    cancelled' = false,
    launched' = false,
    launchCount' = 0,
    previousEpoch' = 0,
  }

  action claim = {
    nondet worker = WORKERS.oneOf()
    all {
      holder == "none",
      not(cancelled),
      not(launched),
      holder' = worker,
      epoch' = epoch + 1,
      version' = version + 1,
      cancelled' = cancelled,
      launched' = launched,
      launchCount' = launchCount,
      previousEpoch' = epoch,
    }
  }

  // The adapter gets the immutable effect ID only after a durable CAS claim.
  // There is no transition for a second launch while one is outstanding.
  action launch = all {
    holder != "none",
    not(cancelled),
    not(launched),
    launched' = true,
    launchCount' = launchCount + 1,
    version' = version,
    epoch' = epoch,
    holder' = holder,
    cancelled' = cancelled,
    previousEpoch' = epoch,
  }

  // Revoke/cancel fences old worker identity and leaves any external launch
  // outstanding for verified cleanup. It never marks successful termination.
  action cancel = all {
    not(cancelled),
    cancelled' = true,
    epoch' = epoch + 1,
    version' = version + 1,
    holder' = "none",
    launched' = launched,
    launchCount' = launchCount,
    previousEpoch' = epoch,
  }

  // Crashes, lost/duplicated event wakeups cannot edit persisted CAS state.
  action restart = all {
    version' = version,
    epoch' = epoch,
    holder' = holder,
    cancelled' = cancelled,
    launched' = launched,
    launchCount' = launchCount,
    previousEpoch' = epoch,
  }

  action step = any { claim, launch, cancel, restart }

  val singleExternalLaunch = launchCount <= 1
  val noHolderAfterCancellation = cancelled implies holder == "none"
  val noUnclaimedLaunch = launched implies version > 0
  val monotonicallyFenced = epoch >= previousEpoch

  val safety = singleExternalLaunch and noHolderAfterCancellation
    and noUnclaimedLaunch and monotonicallyFenced

  // Both a real claimed state and an external-launch state must be reachable.
  val noClaimWitness = not(holder == "workerB" and launchCount == 0)
  val noLaunchWitness = not(launched and launchCount == 1)
}
