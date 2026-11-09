// Finite abstraction. Owner IDs: producer 0, pool 1, direct investor 2.
// Project scope 0, membership scope 1, optional investment scope 2.
module capital {
  type Effect = { kind: str, scope: int, revision: int, seller: int,
    serials: Set[int], amount: int, allocation: int -> int }
  type Request = { tx: int, source: int, body: Effect, receipt: Effect,
    signed: bool, independent: bool, policy: bool, allocationApproved: bool, solvent: bool,
    quoteUntil: int, quoteRate: int }
  type Ledger = { owners: int -> int, revision: int, retained: int, liquid: int,
    membership: int, optionalCapital: int, now: int, sellerRevoked: bool,
    txs: Set[int], sources: Set[int], accepted: int, sold: int, violations: Set[str] }

  pure val serials = 0.to(3)
  pure val holders = 0.to(2)
  pure val empty = Map(0 -> 0, 1 -> 0, 2 -> 0)
  pure val initial = { owners: Map(0 -> 0, 1 -> 1, 2 -> 1, 3 -> 2),
    revision: 0, retained: 2, liquid: 7, membership: 3, optionalCapital: 4, now: 0,
    sellerRevoked: false, txs: Set(), sources: Set(), accepted: 0, sold: 0, violations: Set() }

  var s: Ledger

  pure def request(tx: int, source: int, body: Effect): Request =
    { tx: tx, source: source, body: body, receipt: body, signed: true,
      independent: true, policy: true, allocationApproved: true, solvent: true,
      quoteUntil: 0, quoteRate: 2 }
  pure def buy(tx: int, revision: int, seller: int, units: Set[int]): Request =
    request(tx, tx, { kind: "sale", scope: 0, revision: revision,
      seller: seller, serials: units, amount: 2 * units.size(), allocation: empty })
  pure def finance(tx: int, revision: int, kind: str, amount: int, plan: int -> int): Request =
    request(tx, tx, { kind: kind, scope: 0, revision: revision,
      seller: 0, serials: Set(), amount: amount, allocation: plan })
  pure def coop(tx: int, source: int, scope: int): Request =
    request(tx, source, { kind: "coop", scope: scope, revision: 0,
      seller: 0, serials: Set(), amount: 1, allocation: empty })

  pure def allocationsOK(x: Ledger, b: Effect, amount: int): bool =
    holders.fold(0, (sum, i) => sum + b.allocation.get(i)) == amount and
    holders.forall(i => b.allocation.get(i) >= 0 and
      (b.allocation.get(i) == 0 or serials.exists(j => x.owners.get(j) == i)))

  pure def note(x: Ledger, good: bool, name: str): Ledger =
    if (good) x else x.with("violations", x.violations.union(Set(name)))

  pure def recordEffect(x: Ledger, r: Request): Ledger =
    x.with("txs", x.txs.union(Set(r.tx))).with("sources", x.sources.union(Set(r.source)))
      .with("accepted", x.accepted + 1)

  // Mutants suppress one guard. The monitors still observe actual effects and preconditions.
  pure def applyRequest(x: Ledger, r: Request, omit: str): Ledger = {
    val b = r.body
    val txFresh = not(x.txs.contains(r.tx))
    val sourceFresh = not(x.sources.contains(r.source))
    val signed = r.signed and (b.kind != "sale" or not(x.sellerRevoked))
    val bound = r.receipt == b
    if ((txFresh or omit == "tx") and (sourceFresh or omit == "source") and
        (signed or omit == "authorization") and (bound or omit == "binding") and
        r.independent and r.policy) {
      val used = recordEffect(note(note(x, signed, "authorization"), bound, "binding"), r)
      if (b.kind == "coop" and b.amount == 1) {
        if (b.scope == 1 and x.membership >= b.amount)
          used.with("membership", x.membership - b.amount)
        else if (b.scope == 2 and x.optionalCapital >= b.amount)
          used.with("optionalCapital", x.optionalCapital - b.amount)
        else x
      } else if (b.scope == 0 and (b.revision == x.revision or omit == "revision")) {
        val advanced = note(used, b.revision == x.revision, "revision").with("revision", x.revision + 1)
        if (b.kind == "sale") {
          val owned = b.serials.forall(i => x.owners.get(i) == b.seller)
          val current = x.now <= r.quoteUntil
          if (b.seller.in(Set(1, 2)) and b.serials.size() > 0 and b.serials.subseteq(serials) and
              (owned or omit == "ownership") and (current or omit == "valuation") and
              r.quoteRate > 0 and b.amount == r.quoteRate * b.serials.size())
            note(note(advanced, current, "valuation"), owned, "ownership")
              .with("owners", b.serials.fold(x.owners, (table, i) => table.set(i, 0)))
              .with("sold", x.sold + b.serials.size())
          else x
        } else if (b.kind == "earnings") {
          val exact = allocationsOK(x, b, -b.amount)
          if ((b.amount > 0 and b.allocation == empty) or
              (b.amount < 0 and r.allocationApproved and (exact or omit == "loss")))
            note(advanced, b.amount >= 0 or exact, "loss").with("retained", x.retained + b.amount)
          else x
        } else if (b.kind == "distribution") {
          val covered = b.amount <= x.retained
          val funded = b.amount + 3 <= x.liquid // two in liabilities and one in reserves
          if (b.amount > 0 and allocationsOK(x, b, b.amount) and r.allocationApproved and
              (covered or omit == "profit") and (funded or omit == "assets") and
              (r.solvent or omit == "solvency"))
            note(note(note(advanced, covered, "profit"), funded, "assets"), r.solvent, "solvency")
              .with("retained", x.retained - b.amount).with("liquid", x.liquid - b.amount)
          else x
        } else x
      } else x
    } else x
  }

  action init = s' = initial
  action attempt(r: Request): bool = {
    val after = applyRequest(s, r, "")
    val scope = r.body.scope
    val projectUnchanged = after.owners == s.owners and after.revision == s.revision and
      after.retained == s.retained and after.liquid == s.liquid
    val scopeSafe = if (scope == 0)
        after.membership == s.membership and after.optionalCapital == s.optionalCapital
      else if (scope == 1) projectUnchanged and after.optionalCapital == s.optionalCapital
      else if (scope == 2) projectUnchanged and after.membership == s.membership
      else after == s
    s' = note(after, scopeSafe, "scope")
  }
  action mutate(r: Request, omit: str): bool = s' = applyRequest(s, r, omit)
  action tick = s' = s.with("now", 1)
  action revoke = s' = s.with("sellerRevoked", true)

  pure val a = buy(1, 0, 1, Set(1))
  pure val b = buy(2, 0, 1, Set(2))
  pure val forged = buy(3, 0, 1, Set(3))
  pure val mismatched = a.with("receipt", b.body)
  pure val denied = a.with("signed", false)
  pure def refreshed(x: Ledger): Request = buy(3, x.revision, 1, Set(1))
  pure def otherSeller(x: Ledger): Request = buy(4, x.revision, 2, Set(3))
  pure def gain(x: Ledger): Request = finance(5, x.revision, "earnings", 4, empty)
  pure def loss(x: Ledger): Request = finance(6, x.revision, "earnings", -3, empty.set(0, 3))
  pure def badLoss(x: Ledger): Request = finance(6, x.revision, "earnings", -3, empty.set(0, 2))
  pure def payout(x: Ledger, amount: int): Request =
    finance(7, x.revision, "distribution", amount, empty.set(0, amount))

  action step = any {
    tick, revoke, attempt(a), attempt(b), attempt(refreshed(s)), attempt(otherSeller(s)),
    attempt(forged), attempt(mismatched), attempt(denied), attempt(a.with("policy", false)),
    attempt(a.with("independent", false)), attempt(gain(s)), attempt(loss(s)), attempt(badLoss(s)),
    attempt(payout(s, 1)), attempt(payout(s, 5)), attempt(payout(s, 1).with("solvent", false)),
    attempt(loss(s).with("allocationApproved", false)), attempt(coop(8, 8, 1)),
    attempt(coop(9, 9, 2)), attempt(coop(8, 5, 1)), attempt(coop(5, 9, 2))
  }

  val conservation = s.owners.keys() == serials and
    serials.filter(i => s.owners.get(i) == 0).size() +
    serials.filter(i => s.owners.get(i) == 1).size() +
    serials.filter(i => s.owners.get(i) == 2).size() == 4
  val noDoubleSale = s.sold + 1 == serials.filter(i => s.owners.get(i) == 0).size()
  val oncePerTx = s.accepted == s.txs.size()
  val oncePerSource = s.accepted == s.sources.size()
  val revisionSafe = not(s.violations.contains("revision"))
  val valuationSafe = not(s.violations.contains("valuation"))
  val authoritySafe = not(s.violations.contains("authorization"))
  val ownershipSafe = not(s.violations.contains("ownership"))
  val receiptSafe = not(s.violations.contains("binding"))
  val lossSafe = not(s.violations.contains("loss"))
  val profitSafe = not(s.violations.contains("profit"))
  val assetsSafe = not(s.violations.contains("assets")) and s.liquid >= 3
  val solvencySafe = not(s.violations.contains("solvency"))
  val scopeSafe = not(s.violations.contains("scope"))
  val safety = conservation and noDoubleSale and oncePerTx and oncePerSource and revisionSafe and
    valuationSafe and authoritySafe and ownershipSafe and receiptSafe and lossSafe and profitSafe and
    assetsSafe and solvencySafe and scopeSafe and s.membership >= 0 and s.optionalCapital >= 0

  action badRevision = any { step, mutate(b, "revision") }
  action doubleSale = any { step, mutate(refreshed(s), "ownership") }
  action staleAppraisal = any { step, mutate(a, "valuation") }
  action unauthorized = any { step, mutate(denied, "authorization") }
  action fakeOwnership = any { step, mutate(forged, "ownership") }
  action forgedReceipt = any { step, mutate(mismatched, "binding") }
  action replayTx = any { step, mutate(coop(5, 9, 2), "tx") }
  action replaySource = any { step, mutate(coop(8, 5, 1), "source") }
  action underallocatedLoss = any { step, mutate(badLoss(s), "loss") }
  action deficitPayout = any { step, mutate(payout(s, 1), "profit") }
  action unfundedPayout = any { step, mutate(payout(s, 5), "assets") }
  action insolventPayout = any { step, mutate(payout(s, 1).with("solvent", false), "solvency") }

  run competingSnapshotTest = init.then(attempt(a)).then(attempt(b)).then(attempt(refreshed(s)))
    .expect(s.revision == 1 and s.owners.get(1) == 0 and s.owners.get(2) == 1 and safety)
  run reverseSnapshotTest = init.then(attempt(b)).then(attempt(a))
    .expect(s.revision == 1 and s.owners.get(1) == 1 and s.owners.get(2) == 0 and safety)
  run staleAndRevokedTest = init.then(tick).then(attempt(a)).then(revoke)
    .then(attempt(b.with("quoteUntil", 1))).expect(s.revision == 0 and safety)
  run forgedEvidenceTest = init.then(attempt(forged)).then(attempt(mismatched)).then(attempt(denied))
    .expect(s == initial and safety)
  run crossScopeReplayTest = init.then(attempt(gain(s))).then(attempt(coop(8, 5, 1)))
    .then(attempt(coop(5, 9, 2))).then(attempt(coop(8, 8, 1)))
    .expect(s.accepted == 2 and s.membership == 2 and s.optionalCapital == 4 and safety)
  run policyAndSolvencyTest = init.then(attempt(payout(s, 1).with("solvent", false)))
    .then(attempt(loss(s).with("allocationApproved", false)))
    .then(attempt(payout(s, 1).with("allocationApproved", false))).expect(s == initial and safety)
  run earningsAndAssetsTest = init.then(attempt(badLoss(s))).then(attempt(loss(s)))
    .then(attempt(payout(s, 1))).then(attempt(gain(s))).then(attempt(payout(s, 5)))
    .then(attempt(payout(s, 1))).expect(s.accepted == 3 and s.retained == 2 and s.liquid == 6 and safety)
}
