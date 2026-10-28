// DELIBERATELY WRONG: credit a notification without consent or source proof.
// Must typecheck and produce a genuine Quint invariant violation.
module eatsbot_marketing_bug {
  var consent: bool
  var verified: bool
  var credited: bool

  action init = all {
    consent' = false,
    verified' = false,
    credited' = false,
  }

  action untrustedCredit = all {
    not(credited),
    credited' = true,
    consent' = consent,
    verified' = verified,
  }

  action step = any { untrustedCredit }
  val safety = credited implies (consent and verified)
}
