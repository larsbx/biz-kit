// keel: "Invalid/cyclic temporal ownership cannot grant active permissions".
// Abstracts Keel.Org.can?/4: a permission comes only from roles held at t
// (Org.roles/3 over Org.edges/3, which keeps an edge only when
// Interval.contains?(during, t), so expired and empty intervals grant nothing)
// and their effective grants (Org.effective/3, direct delegation lines at t).
// and Keel.Invariants.valid_at?/2: can?/4 grants nothing at t when the org
// is not well formed at t (every static invariant and every temporal one at
// t: cycles in reports, delegation or ownership, bad intervals, seat limits).
// Keel SPEC §4 `can` and amendment A6; tested by OrgTest "an invalid org
// grants nothing".
// Abstracted away: one party, one seat edge, one delegation line; time is
// the seat interval being active or not; capability coverage and alienation
// reservations are omitted. GUARDED switches off both halves of the gate.
module keel_spec {
  const GUARDED: bool
  type Grant = { active: bool, valid: bool }

  var seatActive: bool     // the seat edge's interval contains t
  var cyclic: bool         // delegation or ownership graph has a cycle at t
  var granted: Set[Grant]
  var refused: int

  action init = all { seatActive' = true, cyclic' = false, granted' = Set(), refused' = 0 }

  action advanceTime(active) = all {
    seatActive' = active, cyclic' = cyclic, granted' = granted, refused' = refused,
  }

  action addDelegation(makesCycle) = all {
    cyclic' = makesCycle, seatActive' = seatActive, granted' = granted, refused' = refused,
  }

  action can = {
    val ok = seatActive and not(cyclic)
    all {
      seatActive' = seatActive, cyclic' = cyclic,
      if (ok or not(GUARDED)) all {
        granted' = granted.union(Set({ active: seatActive, valid: not(cyclic) })),
        refused' = refused,
      } else all { granted' = granted, refused' = refused + 1 },
    }
  }

  action step = any {
    nondet a = Set(true, false).oneOf() advanceTime(a),
    nondet c = Set(true, false).oneOf() addDelegation(c),
    can,
  }

  // Every granted permission came from an active edge of a valid, acyclic organization.
  val obligation = granted.forall(g => g.active and g.valid)
  // A permission was granted, and a query over an expired or cyclic organization was refused.
  val obligationWitness = not(granted.size() > 0 and refused > 0)
}

module keel { import keel_spec(GUARDED = true).* }
module keel_control { import keel_spec(GUARDED = false).* }
