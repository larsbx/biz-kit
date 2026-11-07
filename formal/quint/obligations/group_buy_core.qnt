// group_buy_core: "Pledges bind exactly once on threshold, distinct from stock
// and money movement."
//
// Models GroupBuyCore.BindingRound.apply/4 and transition/4 (apps/group_buy_core/
// lib/group_buy_core/binding_round.ex):
// - `activated` is set in the same transition that first brings the active
//   quantity to the first tier's min_quantity, and is never replaced.
// - After activation a withdraw returns :binding_pledge_cannot_be_withdrawn,
//   and a later valid pledge joins as immediately binding.
// - The module never reserves stock or moves money ("does not charge, take
//   custody, reserve stock").
// Abstracted: unit pledges from buyers a/b/c, threshold 2, no prices, no
// expiry, no versions. GUARDED switches off both rules (keep the first
// activation, refuse post-activation withdrawal).
module group_buy_core_spec {
  const GUARDED: bool

  pure val BUYERS = Set("a", "b", "c")
  pure val THRESHOLD = 2

  var pledged: Set[str]
  var activated: bool
  var activations: int         // times a transition set `activated`
  var boundAtActivation: Set[str]
  var stockMoved: int
  var moneyMoved: int

  action init = all {
    pledged' = Set(), activated' = false, activations' = 0,
    boundAtActivation' = Set(), stockMoved' = 0, moneyMoved' = 0,
  }

  action pledge(b: str): bool = {
    val joined = pledged.union(Set(b))
    val crosses = joined.size() >= THRESHOLD
    val activate = crosses and (not(activated) or not(GUARDED))
    all {
      not(pledged.contains(b)),
      pledged' = joined,
      activated' = (activated or crosses),
      activations' = if (activate) activations + 1 else activations,
      boundAtActivation' = if (activate) joined else boundAtActivation,
      stockMoved' = stockMoved, moneyMoved' = moneyMoved,
    }
  }

  action withdraw(b: str): bool = all {
    pledged.contains(b),
    not(GUARDED) or not(activated),
    pledged' = pledged.exclude(Set(b)),
    activated' = activated, activations' = activations,
    boundAtActivation' = boundAtActivation, stockMoved' = stockMoved, moneyMoved' = moneyMoved,
  }

  action step = nondet b = BUYERS.oneOf()
    any { pledge(b), withdraw(b) }

  val obligation = all {
    activations <= 1,
    activated implies (activations == 1 and boundAtActivation.size() >= THRESHOLD
                       and boundAtActivation.subseteq(pledged)),
    stockMoved == 0, moneyMoved == 0,
  }

  // The round bound and a later pledge joined it.
  val obligationWitness = not(activated and pledged.size() == 3)
}

module group_buy_core {
  import group_buy_core_spec(GUARDED = true).*
}

module group_buy_core_control {
  import group_buy_core_spec(GUARDED = false).*
}
