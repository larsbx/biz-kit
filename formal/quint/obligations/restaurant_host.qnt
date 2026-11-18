// restaurant_host: "The host obtains a governance signature only on the grant
// it showed, and the governance seed never leaves the administrator."
//
// Models RestaurantHost.DeviceGrants (apps/restaurant_host/lib/restaurant_host/
// device_grants.ex) with CoopSubstrate.Governance.Client.sign_held/4
// (apps/coop_substrate/lib/coop_substrate/governance/client.ex): the host
// shows a grant (details/2), holds signing bytes (prepare/3 via Commands.hold/5),
// and the administrator's machine decodes those bytes and signs only when
// `expected` (DeviceGrants.grants?/2) and signed_by?/2 hold. It sends back
// only `Crypto.sign(bytes, seed)`, never the seed.
// Abstracted: grants as small integers, signatures as the signed payload. The
// host is adversarial: it may hold bytes for any grant. GUARDED switches off
// the `expected` comparison on the administrator's machine.
module restaurant_host_spec {
  const GUARDED: bool

  pure val GRANTS = 1.to(3)

  var shown: Set[int]          // grants the host displayed to the administrator
  var signedFor: Set[int]      // payloads the host holds a governance signature on
  var seedSent: bool           // anything the administrator sent carried the seed

  action init = all { shown' = Set(), signedFor' = Set(), seedSent' = false }

  action show(g: int): bool = all {
    shown' = shown.union(Set(g)), signedFor' = signedFor, seedSent' = seedSent,
  }

  // The host asks for a signature on `held` after showing `displayed`.
  action requestSignature(displayed: int, held: int): bool = all {
    shown.contains(displayed),
    not(GUARDED) or held == displayed,       // expected.(core): grants?/2
    signedFor' = signedFor.union(Set(held)),  // reply carries the signature only
    seedSent' = seedSent,
    shown' = shown,
  }

  action step = nondet d = GRANTS.oneOf()
    nondet h = GRANTS.oneOf()
    any { show(d), requestSignature(d, h) }

  val obligation = signedFor.subseteq(shown) and not(seedSent)

  // The administrator signed a grant the host had shown.
  val obligationWitness = signedFor == Set()
}

module restaurant_host {
  import restaurant_host_spec(GUARDED = true).*
}

module restaurant_host_control {
  import restaurant_host_spec(GUARDED = false).*
}
