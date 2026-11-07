// Obligation (marketing_core): only authenticated, timely delivery can qualify
// for attribution.
//
// Rule in code: MarketingCore.Attribution.eligible?/3 is true only for evidence
// with delivery_status :confirmed and a delivered_at, a check-in within
// [0, window] after delivery, and any prior attribution strictly earlier.
// FINDING: "authenticated" is the caller's :confirmed flag. The module does not
// verify the evidence itself; its moduledoc leaves that to the host.
// Abstracted: times are 0..3, window = 1; one subscriber, one merchant.
module marketing_core_spec {
  const GUARDED: bool
  val T = 0.to(3)
  val WINDOW = 1
  var status: str        // "queued" | "confirmed" (independently confirmed delivery)
  var deliveredAt: int
  var lastAttributed: int  // -1: never attributed
  var attributed: bool
  var timely: bool       // ghost: the last attribution satisfied the rule

  action init = all { status' = "queued", deliveredAt' = 0, lastAttributed' = -1,
    attributed' = false, timely' = true }
  action deliver = {
    nondet st = Set("queued", "confirmed").oneOf()
    nondet at = T.oneOf()
    all { status' = st, deliveredAt' = at, lastAttributed' = lastAttributed,
      attributed' = attributed, timely' = timely }
  }
  def eligible(checkIn) = all {
    status == "confirmed",
    checkIn - deliveredAt >= 0, checkIn - deliveredAt <= WINDOW,
    lastAttributed < deliveredAt,
  }
  action checkIn = {
    nondet c = T.oneOf()
    all { not(GUARDED) or eligible(c), status' = status, deliveredAt' = deliveredAt,
      lastAttributed' = deliveredAt, attributed' = true, timely' = eligible(c) }
  }
  action stutter = all { status' = status, deliveredAt' = deliveredAt,
    lastAttributed' = lastAttributed, attributed' = attributed, timely' = timely }
  action step = any { deliver, checkIn, stutter }

  val obligation = attributed implies timely
  val obligationWitness = not(attributed)
}
module marketing_core { import marketing_core_spec(GUARDED = true).* }
module marketing_core_control { import marketing_core_spec(GUARDED = false).* }
