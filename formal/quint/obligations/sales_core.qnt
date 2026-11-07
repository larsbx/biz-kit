// Obligation (sales_core): withdrawal prevents subsequent marketing, including a
// stale regrant or a replayed grant.
//
// Rule in code: SalesCore.Consent.record/3 and allowed?/6. Every grant or
// withdrawal must be strictly newer than the key's current entry (newer/3);
// a grant's evidence_ref must never have been used (distinct_new_evidence?/3,
// used_receipts survives withdrawal); allowed?/6 needs status :granted.
// Abstracted: one {party, channel, jurisdiction} key; times 1..3; two receipts.
module sales_core_spec {
  const GUARDED: bool
  val T = 1.to(3)
  val EVIDENCE = Set("e1", "e2")
  var granted: bool
  var at: int
  var used: Set[str]
  var withdrawnAt: int     // ghost: latest admitted withdrawal (0: none)
  var usedBefore: Set[str] // ghost: receipts used before that withdrawal
  var grantAt: int
  var grantEvidence: str

  action init = all { granted' = false, at' = 0, used' = Set(), withdrawnAt' = 0,
    usedBefore' = Set(), grantAt' = 0, grantEvidence' = "" }
  action grant = {
    nondet t = T.oneOf()
    nondet e = EVIDENCE.oneOf()
    all { not(GUARDED) or (t > at and not(e.in(used))),
      granted' = true, at' = t, used' = used.union(Set(e)), grantAt' = t, grantEvidence' = e,
      withdrawnAt' = withdrawnAt, usedBefore' = usedBefore }
  }
  action withdraw = {
    nondet t = T.oneOf()
    all { not(GUARDED) or t > at, granted' = false, at' = t, used' = used,
      withdrawnAt' = t, usedBefore' = used, grantAt' = grantAt, grantEvidence' = grantEvidence }
  }
  action stutter = all { granted' = granted, at' = at, used' = used, withdrawnAt' = withdrawnAt,
    usedBefore' = usedBefore, grantAt' = grantAt, grantEvidence' = grantEvidence }
  action step = any { grant, withdraw, stutter }

  // Marketing is allowed only on a grant newer than the last withdrawal, whose
  // receipt was not already spent before that withdrawal.
  val obligation = granted implies (grantAt > withdrawnAt and not(grantEvidence.in(usedBefore)))
  val obligationWitness = not(granted and withdrawnAt > 0)
}
module sales_core { import sales_core_spec(GUARDED = true).* }
module sales_core_control { import sales_core_spec(GUARDED = false).* }
