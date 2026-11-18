// procurement_host: "A command is re-signed only after an explicit pre-append
// clock-boundary refusal, at most three attempts, and never after an outcome
// that may have committed".
//
// Rule modelled: ProcurementHost.Admission.run/1 retries a ledger call only on
// {:error, :stale_procurement_admission_time} (or the Log's
// {:reject, 0, :stale_procurement_admission_time}), which the Log returns
// before appending anything, and stops after three attempts. Success, any
// other refusal, a timeout, an exit or an exception ends it, so an outcome
// that may have committed is never replayed. Tested by
// ProcurementHost.AdmissionTest.
// Abstracted: one command; each attempt's outcome is chosen by the
// environment: "ok" (appended), "stale" (refused before append), "refused"
// (refused, nothing appended) or "unknown" (a timeout or exit that may have
// appended). GUARDED is Admission's retry rule; the control retries every
// outcome but success, up to five attempts.
module procurement_host_spec {
  const GUARDED: bool
  val Outcomes = Set("ok", "stale", "refused", "unknown")
  var attempts: int
  var last: str              // "none" before the first attempt
  var done: bool
  var replayed: bool         // ghost: an attempt followed one that may have committed
  var staleRetried: bool     // ghost: an attempt followed a clock refusal

  val retry = if (GUARDED) last == "stale" and attempts < 3 else last != "ok" and attempts < 5

  action attempt = all {
    not(done), attempts == 0 or retry,
    nondet o = Outcomes.oneOf()
    all {
      attempts' = attempts + 1, last' = o, done' = done,
      replayed' = (replayed or last == "ok" or last == "unknown"),
      staleRetried' = (staleRetried or last == "stale"),
    },
  }

  action finish = all {
    not(done), attempts > 0, not(retry),
    attempts' = attempts, last' = last, done' = true,
    replayed' = replayed, staleRetried' = staleRetried,
  }

  action stutter = all {
    done,
    attempts' = attempts, last' = last, done' = done,
    replayed' = replayed, staleRetried' = staleRetried,
  }

  action init = all {
    attempts' = 0, last' = "none", done' = false, replayed' = false, staleRetried' = false,
  }

  action step = any { attempt, finish, stutter }

  // At most three attempts, and none after an outcome that may have committed.
  val obligation = attempts <= 3 and not(replayed)
  // A clock refusal was re-signed and the retry was admitted.
  val obligationWitness = not(staleRetried and last == "ok" and done)
}
module procurement_host { import procurement_host_spec(GUARDED = true).* }
module procurement_host_control { import procurement_host_spec(GUARDED = false).* }
