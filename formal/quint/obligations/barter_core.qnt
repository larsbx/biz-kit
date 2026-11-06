// barter_core: "An optimizer preview cannot transfer assets without separately
// signed admission."
//
// Models BarterCore.Optimizer.optimize/3 and BarterCore.Brokerage.draft/3 and
// pre_delivery_preview/3 (apps/barter_core/lib/barter_core/): they return a
// plan and conditional legs with `status: :not_admitted`,
// `company_takes_title: false` and `:requires_independent_authorized_local_admission`.
// They never change ownership. The `admit` action stands for the host's
// separate admission, which needs the provider's signature.
// Finding: barter_core only enforces the preview half. It contains no
// admission path, which its moduledoc leaves to the host; this models that
// intended rule.
// Abstracted: two assets and three participants, a cycle as one swap of owners.
// GUARDED switches off the preview's no-effect rule: the control applies the
// planned legs to ownership.
module barter_core_spec {
  const GUARDED: bool

  pure val ASSETS = Set("bike", "tools")
  pure val PEOPLE = Set("p1", "p2", "p3")

  var owner: str -> str
  var signedTransfers: Set[(str, str)]   // (asset, new owner) a provider signed
  var previews: int

  action init = all {
    owner' = Map("bike" -> "p1", "tools" -> "p2"), signedTransfers' = Set(), previews' = 0,
  }

  // A preview of the swap bike->p2, tools->p1.
  action preview = all {
    previews' = previews + 1,
    owner' = if (GUARDED) owner else Map("bike" -> owner.get("tools"), "tools" -> owner.get("bike")),
    signedTransfers' = signedTransfers,
  }

  // Host admission of one leg, signed by the asset's current owner.
  action admit(asset: str, recipient: str): bool = all {
    recipient != owner.get(asset),
    signedTransfers' = signedTransfers.union(Set((asset, recipient))),
    owner' = owner.set(asset, recipient),
    previews' = previews,
  }

  action step = nondet a = ASSETS.oneOf()
    nondet r = PEOPLE.oneOf()
    any { preview, admit(a, r) }

  pure val INITIAL = Map("bike" -> "p1", "tools" -> "p2")

  // An asset is only ever held by its first owner or a signed recipient.
  val obligation = ASSETS.forall(a =>
    owner.get(a) == INITIAL.get(a) or signedTransfers.contains((a, owner.get(a))))

  // Previews were made, and nothing was admitted.
  val obligationWitness = not(previews >= 1 and signedTransfers == Set())
}

module barter_core {
  import barter_core_spec(GUARDED = true).*
}

module barter_core_control {
  import barter_core_spec(GUARDED = false).*
}
