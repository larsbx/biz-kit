// Independent bounded oracle for the unsigned cross-currency preview.
// The arithmetic searches every integer pair, using cross multiplication;
// it deliberately does not implement the Elixir min-of-quotients algorithm.
// Source records and agreement fields are HOST ASSERTIONS, not authentication.
module ExactSetoff {
  type Arithmetic = { status: int, quote: int, base: int,
    quoteResidual: int, baseResidual: int }
  type Source = { id: int, debtor: int, creditor: int, currency: int,
    amount: int, revision: int, evidence: int, until: int, eligible: bool }
  type Rate = { baseCurrency: int, quoteCurrency: int, numerator: int,
    denominator: int, agreedAt: int, until: int, evidence: int, agreement: int }
  type Terms = { quoteSource: Source, baseSource: Source, rate: Rate,
    intent: int, observedAt: int }
  type Reduction = { sourceId: int, sourceRevision: int, currency: int,
    original: int, reduced: int, residual: int }
  type Total = { currency: int, original: int, reduced: int, residual: int }
  type Plan = { accepted: bool, terms: Terms, commitmentPreimage: Terms,
    reductions: List[Reduction],
    totals: List[Total], perCurrencyOnly: bool, unsigned: bool,
    discharge: bool, accountingPosted: bool, fxExecuted: bool,
    settlementExecuted: bool, authorityAuthenticated: bool,
    legalClassificationDetermined: bool }

  pure val maxMinor = 9007199254740991
  pure def positiveBounded(x: int): bool = x > 0 and x <= maxMinor

  // A reduced positive fraction has no positive common divisor other than 1.
  // The bounded harness limits rates to 0..5 before evaluating this search.
  pure def canonical(n: int, d: int): bool =
    n > 0 and d > 0 and 1.to(n).forall(g =>
      n % g != 0 or d % g != 0 or g == 1)

  pure def pairs(q: int, b: int, n: int, d: int): Set[(int, int)] =
    tuples(0.to(q), 0.to(b)).filter(p => p._1 * d == p._2 * n)

  pure def largest(q: int, b: int, n: int, d: int): (int, int) =
    pairs(q, b, n, d).fold((0, 0), (best, p) =>
      if (p._2 > best._2) p else best)

  // status 0 = rejected shape/range/noncanonical rate; 1 = no positive exact
  // pair; 2 = accepted arithmetic. Error rows leave both input amounts unchanged.
  pure def evaluate(q: int, b: int, n: int, d: int): Arithmetic = {
    val empty = { status: 0, quote: 0, base: 0, quoteResidual: q, baseResidual: b }
    if (not(positiveBounded(q) and positiveBounded(b) and
        positiveBounded(n) and positiveBounded(d) and canonical(n, d))) empty
    else {
      val p = largest(q, b, n, d)
      if (p._1 == 0 or p._2 == 0) empty.with("status", 1)
      else { status: 2, quote: p._1, base: p._2,
        quoteResidual: q - p._1, baseResidual: b - p._2 }
    }
  }

  pure def row(q: int, b: int, n: int, d: int): List[int] = {
    val a = evaluate(q, b, n, d)
    List(a.status, a.quote, a.base, a.quoteResidual, a.baseResidual)
  }

  pure def arithmeticInvariant(q: int, b: int, n: int, d: int): bool = {
    val a = evaluate(q, b, n, d)
    if (a.status == 0)
      not(positiveBounded(q) and positiveBounded(b) and
        positiveBounded(n) and positiveBounded(d) and canonical(n, d))
    else if (a.status == 1)
      not(pairs(q, b, n, d).exists(p => p._1 > 0 and p._2 > 0))
    else all {
      a.status == 2,
      a.quote > 0, a.base > 0,
      a.quote <= q, a.base <= b,
      a.quoteResidual >= 0, a.baseResidual >= 0,
      a.quote + a.quoteResidual == q,
      a.base + a.baseResidual == b,
      a.quote * d == a.base * n,
      pairs(q, b, n, d).forall(p => p._1 <= a.quote and p._2 <= a.base),
    }
  }

  pure def sourceOK(s: Source, now: int): bool = all {
    s.id > 0, s.debtor > 0, s.creditor > 0, s.debtor != s.creditor,
    s.currency > 0, positiveBounded(s.amount), positiveBounded(s.revision),
    s.evidence > 0, s.until > now, s.eligible,
  }
  pure def inputsOK(a: Source, b: Source, r: Rate, intent: int, now: int): bool = all {
    now >= 0, sourceOK(a, now), sourceOK(b, now),
    a.id != b.id, a.debtor == b.creditor, a.creditor == b.debtor,
    a.currency != b.currency, intent > 0, intent != a.id, intent != b.id,
    r.baseCurrency == b.currency, r.quoteCurrency == a.currency,
    positiveBounded(r.numerator), positiveBounded(r.denominator),
    canonical(r.numerator, r.denominator),
    r.agreedAt >= 0, r.agreedAt <= now, r.until > now,
    r.evidence > 0, r.agreement > 0,
  }
  pure def reduction(s: Source, amount: int): Reduction = {
    sourceId: s.id, sourceRevision: s.revision, currency: s.currency,
    original: s.amount, reduced: amount, residual: s.amount - amount }
  pure def total(s: Reduction): Total = {
    currency: s.currency, original: s.original, reduced: s.reduced,
    residual: s.residual }

  pure def preview(a: Source, b: Source, r: Rate, intent: int, now: int): Plan = {
    val arithmetic = evaluate(a.amount, b.amount, r.numerator, r.denominator)
    val qa = reduction(a, arithmetic.quote)
    val bb = reduction(b, arithmetic.base)
    {
      accepted: inputsOK(a, b, r, intent, now) and arithmetic.status == 2,
      terms: { quoteSource: a, baseSource: b, rate: r, intent: intent, observedAt: now },
      // Ideal transparent commitment to the structured preimage. This is NOT a
      // model of SHA-256, length-prefix encoding, or a collision-resistance proof.
      commitmentPreimage: { quoteSource: a, baseSource: b, rate: r, intent: intent,
        observedAt: now },
      reductions: List(qa, bb),
      totals: if (a.currency < b.currency) List(total(qa), total(bb))
        else List(total(bb), total(qa)),
      perCurrencyOnly: true, unsigned: true, discharge: false,
      accountingPosted: false, fxExecuted: false, settlementExecuted: false,
      authorityAuthenticated: false, legalClassificationDetermined: false,
    }
  }

  // Like verify_plan/2, this recomputes from the candidate's OWN assertions.
  // It does not retrieve latest source records or independently verify consent.
  pure def verify(candidate: Plan, now: int): bool = {
    val t = candidate.terms
    val expected = preview(t.quoteSource, t.baseSource, t.rate, t.intent, now)
    expected.accepted and expected == candidate
  }

  pure val quoteSource: Source = { id: 11, debtor: 1, creditor: 2, currency: 2,
    amount: 8, revision: 1, evidence: 101, until: 10, eligible: true }
  pure val baseSource: Source = { id: 12, debtor: 2, creditor: 1, currency: 1,
    amount: 8, revision: 1, evidence: 102, until: 10, eligible: true }
  pure val rate: Rate = { baseCurrency: 1, quoteCurrency: 2, numerator: 3,
    denominator: 2, agreedAt: 1, until: 10, evidence: 103, agreement: 104 }
  pure val plan = preview(quoteSource, baseSource, rate, 13, 2)

  var active: bool
  action init = active' = true

  // Deterministic finite quantification: 9 * 9 * 6 * 6 = 2,916 input rows.
  // Every feasible reduction pair is independently enumerated inside each row.
  run exhaustiveArithmeticTest = init.expect(
    tuples(0.to(8), 0.to(8), 0.to(5), 0.to(5)).forall(t =>
      arithmeticInvariant(t._1, t._2, t._3, t._4)))

  run explicitArithmeticTest = init.expect(all {
    row(8, 8, 3, 2) == List(2, 6, 4, 2, 4),
    row(1, 1, 3, 2) == List(1, 0, 0, 1, 1),
    row(6, 4, 3, 2) == List(2, 6, 4, 0, 0),
    row(3, 8, 3, 2) == List(2, 3, 2, 0, 6),
    row(1, 1, 1, 1) == List(2, 1, 1, 0, 0),
    row(0, 8, 3, 2) == List(0, 0, 0, 0, 8),
    row(8, 0, 3, 2) == List(0, 0, 0, 8, 0),
  })
  run noncanonicalAndInvalidTest = init.expect(all {
    row(8, 8, 6, 4) == List(0, 0, 0, 8, 8),
    row(8, 8, 2, 2) == List(0, 0, 0, 8, 8),
    row(8, 8, 0, 2) == List(0, 0, 0, 8, 8),
    row(8, 8, 3, 0) == List(0, 0, 0, 8, 8),
    row(8, 8, -3, 2) == List(0, 0, 0, 8, 8),
    row(-1, 8, 3, 2) == List(0, 0, 0, -1, 8),
    not(positiveBounded(maxMinor + 1)), positiveBounded(maxMinor),
  })
  run identityAndCurrencyTest = init.expect(all {
    plan.accepted, verify(plan, 2),
    plan.terms.quoteSource == quoteSource, plan.terms.baseSource == baseSource,
    plan.reductions[0].sourceId == 11, plan.reductions[1].sourceId == 12,
    plan.reductions[0].sourceRevision == 1, plan.reductions[1].sourceRevision == 1,
    plan.reductions[0].currency == 2, plan.reductions[1].currency == 1,
    plan.totals.length() == 2, plan.totals[0].currency == 1,
    plan.totals[1].currency == 2, plan.perCurrencyOnly,
    not(plan.discharge), not(plan.accountingPosted), not(plan.fxExecuted),
    not(plan.settlementExecuted), not(plan.authorityAuthenticated),
    not(plan.legalClassificationDetermined), plan.unsigned,
  })
  run staleAndFutureAgreementTest = init.expect(all {
    not(preview(quoteSource, baseSource, rate.with("until", 2), 13, 2).accepted),
    not(preview(quoteSource, baseSource, rate.with("agreedAt", 3), 13, 2).accepted),
    not(preview(quoteSource.with("until", 2), baseSource, rate, 13, 2).accepted),
    not(preview(quoteSource, baseSource, rate.with("agreement", 0), 13, 2).accepted),
    not(verify(plan, 10)), not(verify(plan, 3)),
  })
  run reciprocalDistinctSourceTest = init.expect(all {
    not(preview(quoteSource, baseSource.with("id", 11), rate, 13, 2).accepted),
    not(preview(quoteSource, baseSource.with("debtor", 3), rate, 13, 2).accepted),
    not(preview(quoteSource, baseSource.with("currency", 2), rate, 13, 2).accepted),
    not(preview(quoteSource, baseSource, rate.with("baseCurrency", 2), 13, 2).accepted),
    not(preview(quoteSource, baseSource, rate, 11, 2).accepted),
  })
  run changedSourceAssertionTest = init.expect(all {
    not(verify(plan.with("terms", plan.terms.with("quoteSource",
      quoteSource.with("revision", 2))), 2)),
    not(verify(plan.with("terms", plan.terms.with("baseSource",
      baseSource.with("id", 99))), 2)),
    not(verify(plan.with("terms", plan.terms.with("rate",
      rate.with("agreement", 999))), 2)),
    not(verify(plan.with("reductions", List(
      plan.reductions[0].with("sourceRevision", 2), plan.reductions[1])), 2)),
  })
  run roundingAndCurrencyAggregationTest = init.expect(all {
    // This altered output still conserves each amount but violates the rate.
    not(verify(plan.with("reductions", List(
      plan.reductions[0].with("reduced", 7).with("residual", 1),
      plan.reductions[1])), 2)),
    not(verify(plan.with("totals", List({ currency: 2, original: 16,
      reduced: 10, residual: 6 })), 2)),
    not(verify(plan.with("perCurrencyOnly", false), 2)),
  })
  run hostAssertionsAreNotAuthenticationTest = init.expect(all {
    // Recomputing ALL fields from a replacement assertion is accepted. This is
    // intentional evidence of the trust boundary, not a forged-source defense.
    verify(preview(quoteSource.with("revision", 2), baseSource, rate, 13, 2), 2),
    verify(preview(quoteSource.with("id", 99), baseSource, rate, 13, 2), 2),
    verify(preview(quoteSource, baseSource, rate.with("agreement", 999), 13, 2), 2),
    not(plan.authorityAuthenticated),
  })
}
