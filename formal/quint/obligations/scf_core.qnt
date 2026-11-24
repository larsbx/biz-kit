// scf_core: "Every reachable ledger preserves debit-credit equality and
// closed-period entries under posting, closure and reversal, with exact-retry
// idempotence and an explicit contract for when a reversal cancels the
// original" (the catalogue's first obligation; its statement-projection half
// is separate and not modelled here).
//
// Rule modelled: ScfCore.Ledger. post/2 admits an entry only if Entry.new/1
// finds it balanced (Σ débit = Σ crédit); a known id with the identical entry
// is a no-op (exact retry), a different entry under a known id is
// {:id_conflict, id}, and an entry dated on or before closed_through is
// {:period_closed, c}. close/2 only moves closed_through forward. reverse/3
// posts the original's lines with sides swapped under a new id, through post/2,
// but merges caller attributes over those lines: the contract is that a
// reversal cancels its original exactly when the caller supplies no `lines`
// ("standard"). Tested by ScfCore.InvariantsTest and ScfCoreTest.
// Abstracted: two accounts, an entry is its signed balance per account
// (débit − crédit), so "balanced" is a + b = 0; three ids, three dates,
// amounts ±1; closed = 0 means no closure yet.
module scf_core_spec {
  const GUARDED: bool
  val Ids = Set(1, 2, 3)
  val Dates = Set(1, 2, 3)
  val Amounts = Set(-1, 1)

  type Entry = { date: int, a: int, b: int, reverses: int, standard: bool }

  var ledger: int -> Entry
  var closed: int
  // ghosts
  var closedWritten: bool   // an entry admitted on or before closed_through
  var overwritten: bool     // a known id was written again (incl. a retry)
  var reopened: bool        // closed_through moved back
  var retried: bool
  var reversed: bool        // a standard reversal was admitted
  var refusedClosed: bool

  val ids = ledger.keys()

  action unchanged = all {
    ledger' = ledger, closed' = closed, closedWritten' = closedWritten,
    overwritten' = overwritten, reopened' = reopened, retried' = retried,
    reversed' = reversed, refusedClosed' = refusedClosed,
  }

  action init = all {
    ledger' = Map(), closed' = 0, closedWritten' = false, overwritten' = false,
    reopened' = false, retried' = false, reversed' = false,
    refusedClosed' = false,
  }

  // Ledger.post/2 (and reverse/3, which posts through it).
  action post(i: int, e: Entry): bool = {
    val balanced = e.a + e.b == 0
    val known = ids.contains(i)
    val retry = known and ledger.get(i) == e
    val inClosed = closed > 0 and e.date <= closed
    val refused = not(balanced) or known or inClosed
    any {
      all {
        // Exact retry: {:ok, l} with the ledger as it was.
        GUARDED and retry,
        ledger' = ledger, closed' = closed, closedWritten' = closedWritten,
        overwritten' = overwritten, reopened' = reopened, retried' = true,
        reversed' = reversed, refusedClosed' = refusedClosed,
      },
      all {
        // {:error, [{:unbalanced, d, c}]}, {:id_conflict, id} or {:period_closed, c}
        GUARDED and not(retry) and refused,
        ledger' = ledger, closed' = closed, closedWritten' = closedWritten,
        overwritten' = overwritten, reopened' = reopened, retried' = retried,
        reversed' = reversed,
        refusedClosed' = (refusedClosed or (balanced and not(known) and inClosed)),
      },
      all {
        not(GUARDED and (retry or refused)),
        ledger' = ledger.put(i, e), closed' = closed,
        closedWritten' = (closedWritten or inClosed),
        overwritten' = (overwritten or known),
        reopened' = reopened, retried' = retried,
        reversed' = (reversed or e.standard),  // only reversals are standard
        refusedClosed' = refusedClosed,
      },
    }
  }

  // Ledger.close/2: {:error, {:cannot_reopen, c}} for an earlier date.
  action close(d: int): bool = any {
    all { GUARDED and closed > 0 and d < closed, unchanged },
    all {
      not(GUARDED and closed > 0 and d < closed),
      ledger' = ledger, closed' = d, closedWritten' = closedWritten,
      overwritten' = overwritten, reopened' = (reopened or d < closed),
      retried' = retried, reversed' = reversed, refusedClosed' = refusedClosed,
    },
  }

  // Ledger.reverse/3: swapped lines, unless the caller's attributes replace them.
  pure def reversal(orig: Entry, o: int, d: int, standard: bool, a: int, b: int): Entry =
    if (standard) { date: d, a: -orig.a, b: -orig.b, reverses: o, standard: true }
    else { date: d, a: a, b: b, reverses: o, standard: false }

  action reverse(o: int, i: int, d: int, standard: bool, a: int, b: int): bool = all {
    ids.contains(o),
    post(i, reversal(if (ids.contains(o)) ledger.get(o) else { date: 0, a: 0, b: 0, reverses: 0, standard: false }, o, d, standard, a, b)),
  }

  action step = {
    nondet i = Ids.oneOf()
    nondet o = Ids.oneOf()
    nondet d = Dates.oneOf()
    nondet a = Amounts.oneOf()
    nondet b = Amounts.oneOf()
    nondet standard = Bool.oneOf()
    any {
      post(i, { date: d, a: a, b: b, reverses: 0, standard: false }),
      close(d),
      reverse(o, i, d, standard, a, b),
    }
  }

  // Σ over the ledger of (débit − crédit), per account, summed: the trial
  // balance's total débit equals its total crédit.
  val trialBalanced = ids.fold(0, (s, i) => s + ledger.get(i).a + ledger.get(i).b) == 0

  // A standard reversal cancels its original, account by account.
  val reversalsCancel = ids.forall(i => {
    val r = ledger.get(i)
    not(r.reverses != 0 and r.standard) or
      (ids.contains(r.reverses) and r.a == -ledger.get(r.reverses).a and r.b == -ledger.get(r.reverses).b)
  })

  val obligation = trialBalanced and reversalsCancel and not(closedWritten) and
    not(overwritten) and not(reopened)

  // A standard reversal was admitted, an exact retry was a no-op, and a
  // closed-period entry was refused.
  val obligationWitness = not(reversed and retried and refusedClosed)
}
module scf_core { import scf_core_spec(GUARDED = true).* }
module scf_core_control { import scf_core_spec(GUARDED = false).* }
