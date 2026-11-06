// Obligation (hawala_capability): test receipts must never be treated as live
// financial settlement.
//
// Rule in code (test-only adapter, compiled only in MIX_ENV=test):
// HawalaCapability.SignedTestPort.verify_response/3 accepts only frames under
// the "hawala/TEST-endpoints/response/v1" domain whose two reserved bytes are
// zero; anything else is {:error, :non_test_or_malformed_response}.
// TestCheckoutOutbox view/1 always reports paid: false and
// financial_authority: false, at most :test_reserved.
// Abstracted: a reply is (domain, claimsPaid); signatures and bindings are
// assumed checked. FINDING: no live financial writer exists here, so the
// obligation is about this adapter's outputs only (README: G3/D5.5 open).
module hawala_capability_spec {
  const GUARDED: bool
  var stage: int        // 0 absent .. 3 test_reserved
  var paid: bool        // what the projected status reports
  var authority: bool   // financial_authority in the projected status
  var liveAccepted: bool  // ghost: a non-TEST frame was accepted

  action init = all { stage' = 0, paid' = false, authority' = false, liveAccepted' = false }
  action reply = {
    nondet domain = Set("TEST", "LIVE").oneOf()
    nondet claimsPaid = Set(false, true).oneOf()
    nondet s = 0.to(3).oneOf()
    all {
      not(GUARDED) or (domain == "TEST" and not(claimsPaid)),
      stage' = s,
      paid' = if (GUARDED) false else claimsPaid,
      authority' = if (GUARDED) false else domain == "LIVE",
      liveAccepted' = (liveAccepted or domain == "LIVE"),
    }
  }
  action stutter = all { stage' = stage, paid' = paid, authority' = authority, liveAccepted' = liveAccepted }
  action step = any { reply, stutter }

  val obligation = not(paid) and not(authority) and not(liveAccepted)
  val obligationWitness = stage != 3
}
module hawala_capability { import hawala_capability_spec(GUARDED = true).* }
module hawala_capability_control { import hawala_capability_spec(GUARDED = false).* }
