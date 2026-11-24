// Bounded model of the review reservation and live legacy fence.
// Ledger replay is abstracted as restoration of the durable state.
// Corporate authority and documentary review are abstract input attestations.
module commercial_setoff_review {
  type State = {
    protected: bool,
    grantsCurrent: bool,
    assigned: bool,
    admitted: Set[int],
    claimed: Set[int],
    legacyWrites: int,
    legacyAtProtection: int
  }

  var s: State

  action init = s' = {
    protected: false,
    grantsCurrent: true,
    assigned: false,
    admitted: Set(),
    claimed: Set(),
    legacyWrites: 0,
    legacyAtProtection: 0
  }

  action enable = all {
    not(s.protected),
    s' = s.with("protected", true).with("legacyAtProtection", s.legacyWrites)
  }

  action legacy = all {
    not(s.protected),
    s.legacyWrites < 1,
    s' = s.with("legacyWrites", s.legacyWrites + 1)
  }

  action revoke = s' = s.with("grantsCurrent", false)

  action assignOutAndBack = all {
    s.claimed == Set(),
    s' = s.with("assigned", true)
  }

  action review(intent: int, exactTerms: bool): bool = {
    val sources = if (intent == 1) Set(1, 2) else Set(1, 3)
    all {
      s.protected,
      s.grantsCurrent,
      not(s.assigned),
      exactTerms,
      not(s.admitted.contains(intent)),
      s.claimed.intersect(sources) == Set(),
      s' = s.with("admitted", s.admitted.union(Set(intent)))
            .with("claimed", s.claimed.union(sources))
    }
  }

  action restart = s' = s

  action step = any {
    enable, legacy, revoke, assignOutAndBack, restart,
    review(1, true), review(2, true), review(1, false), review(2, false)
  }

  val safety = and {
    s.admitted.size() <= 1,
    s.claimed == if (s.admitted.contains(1)) Set(1, 2)
                 else if (s.admitted.contains(2)) Set(1, 3) else Set(),
    not(s.protected) or s.legacyWrites == s.legacyAtProtection,
    s.admitted == Set() or (s.protected and not(s.assigned))
  }

  val noAdmissionAfterLegacy = not(s.admitted.size() == 1 and s.legacyWrites == 1)
}
