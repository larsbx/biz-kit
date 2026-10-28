// R3 abstract source/consent fence for Eatsbot marketing salvage.
// A verified delivery receipt is independent of a queued send. Consent epoch
// is rechecked at the decision, not only when a campaign was proposed.
// This is NOT a model of real signatures, legal consent, DB append or funds.
module eatsbot_marketing_candidate {
  var consent: bool
  var consentEpoch: int
  var deliveryVerified: bool
  var deliveryEpoch: int
  var attributed: bool
  var attributionCount: int
  var creditedWithCurrentConsent: bool

  action init = all {
    consent' = false,
    consentEpoch' = 0,
    deliveryVerified' = false,
    deliveryEpoch' = 0,
    attributed' = false,
    attributionCount' = 0,
    creditedWithCurrentConsent' = false,
  }

  action grant = all {
    not(consent),
    consent' = true,
    consentEpoch' = consentEpoch + 1,
    deliveryVerified' = deliveryVerified,
    deliveryEpoch' = deliveryEpoch,
    attributed' = attributed,
    attributionCount' = attributionCount,
    creditedWithCurrentConsent' = creditedWithCurrentConsent,
  }

  action withdraw = all {
    consent,
    consent' = false,
    consentEpoch' = consentEpoch + 1,
    deliveryVerified' = deliveryVerified,
    deliveryEpoch' = deliveryEpoch,
    attributed' = attributed,
    attributionCount' = attributionCount,
    creditedWithCurrentConsent' = creditedWithCurrentConsent,
  }

  // A real host must authenticate exact delivery receipt bytes. This model
  // only records that source-evidence verification succeeded in this epoch.
  action verifiedDelivery = all {
    consent,
    deliveryVerified' = true,
    deliveryEpoch' = consentEpoch,
    consent' = consent,
    consentEpoch' = consentEpoch,
    attributed' = attributed,
    attributionCount' = attributionCount,
    creditedWithCurrentConsent' = creditedWithCurrentConsent,
  }

  action credit = all {
    consent,
    deliveryVerified,
    deliveryEpoch == consentEpoch,
    not(attributed),
    attributed' = true,
    attributionCount' = attributionCount + 1,
    creditedWithCurrentConsent' = true,
    consent' = consent,
    consentEpoch' = consentEpoch,
    deliveryVerified' = deliveryVerified,
    deliveryEpoch' = deliveryEpoch,
  }

  // Lost wakeups/restart/replayed command hints add no new credit.
  action restart = all {
    consent' = consent,
    consentEpoch' = consentEpoch,
    deliveryVerified' = deliveryVerified,
    deliveryEpoch' = deliveryEpoch,
    attributed' = attributed,
    attributionCount' = attributionCount,
    creditedWithCurrentConsent' = creditedWithCurrentConsent,
  }

  action step = any { grant, withdraw, verifiedDelivery, credit, restart }

  val atMostOneCredit = attributionCount >= 0 and attributionCount <= 1
  val noUnverifiedCredit = attributed implies creditedWithCurrentConsent
  val epochNeverFromFuture = deliveryEpoch <= consentEpoch
  val countMatchesCredit = attributed == (attributionCount == 1)
  val safety = atMostOneCredit and noUnverifiedCredit and epochNeverFromFuture
    and countMatchesCredit

  val noCreditWitness = not(attributed)
}
