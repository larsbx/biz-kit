// Obligation (federation_core): untrusted remote listings can never become
// local business authority.
//
// Rule in code: FederationCore.Marketplace.decode_verified/2 admits an activity
// only if its claimed "actor" equals the transport-verified actor and its
// activity, listing and terms URLs share that actor's origin (same_origin/2,
// attributedTo == actor). The result is a candidate map with no authority
// field: it never names the local seller unless the local seller signed it.
// Host: FederationService is read-only discovery with no business-command
// endpoint; a subscription becomes local authority only through
// CoopSubstrate.FederationAuthority.port/1 (a signed local grant admitted with
// a revocation fence). The pilot approval_verifier path lacks that atomic
// fence (FederationService.SubscriptionAuthority moduledoc).
// Abstracted: two origins; an activity is (verified transport origin, claimed
// actor origin, listing origin). The host's own policy is out of scope.
module federation_core_spec {
  const GUARDED: bool
  val ORIGINS = Set("local", "remote")
  var accepted: Set[{ verified: str, actor: str, listing: str }]

  action init = accepted' = Set()
  action receive = {
    nondet v = ORIGINS.oneOf()
    nondet a = ORIGINS.oneOf()
    nondet l = ORIGINS.oneOf()
    all {
      not(GUARDED) or (a == v and l == v),
      accepted' = accepted.union(Set({ verified: v, actor: a, listing: l })),
    }
  }
  action stutter = accepted' = accepted
  action step = any { receive, stutter }

  // Anything a remote transport delivered stays attributed to that remote
  // origin: it never speaks for the local seller or a local listing.
  val obligation = accepted.forall(c => c.verified == "remote" implies
    (c.actor == "remote" and c.listing == "remote"))
  val obligationWitness = not(accepted.exists(c => c.verified == "remote"))
}
module federation_core { import federation_core_spec(GUARDED = true).* }
module federation_core_control { import federation_core_spec(GUARDED = false).* }
