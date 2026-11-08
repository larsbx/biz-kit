module workflow {
  // Finite lifecycle abstraction, not an implementation refinement proof.
  type State = { phase: int, quote: int, accepted: int, evidence: bool, version: int }
  var s: State
  var authorized: bool
  var frozen: int

  action init = all {
    s' = { phase: 0, quote: 0, accepted: 0, evidence: false, version: 0 },
    authorized' = true,
    frozen' = 0,
  }
  action qualify = all {
    authorized, s.phase == 0,
    s' = { ...s, phase: 1, version: s.version + 1 },
    authorized' = authorized, frozen' = frozen,
  }
  action quote = all {
    authorized, s.phase == 1, s.quote < 2,
    s' = { ...s, quote: s.quote + 1, version: s.version + 1 },
    authorized' = authorized, frozen' = frozen,
  }
  action accept = all {
    authorized, s.phase == 1, s.quote > 0, s.accepted == 0,
    s' = { ...s, phase: 2, accepted: s.quote, version: s.version + 1 },
    authorized' = authorized, frozen' = s.quote,
  }
  action fulfill = all {
    authorized, s.phase == 2,
    s' = { ...s, phase: 3, version: s.version + 1 },
    authorized' = authorized, frozen' = frozen,
  }
  action cancel = all {
    authorized, s.phase <= 2,
    s' = { ...s, phase: 4, version: s.version + 1 },
    authorized' = authorized, frozen' = frozen,
  }
  action dispute = all {
    authorized, Set(2, 3).contains(s.phase),
    s' = { ...s, phase: 5, version: s.version + 1 },
    authorized' = authorized, frozen' = frozen,
  }
  action recordEvidence = all {
    authorized, Set(2, 3, 5).contains(s.phase), s.accepted > 0, not(s.evidence),
    s' = { ...s, evidence: true, version: s.version + 1 },
    authorized' = authorized, frozen' = frozen,
  }
  action revoke = all { s' = s, authorized' = false, frozen' = frozen }
  action idle = all { s' = s, authorized' = authorized, frozen' = frozen }
  action step = any { qualify, quote, accept, fulfill, cancel, dispute, recordEvidence, revoke, idle }
  val invariant = all {
    s.accepted == frozen,
    s.evidence implies s.accepted > 0,
    Set(2, 3, 5).contains(s.phase) implies s.accepted > 0,
  }
  run happyPathTest = init.then(qualify).then(quote).then(accept).then(fulfill)
    .expect(all { invariant, s.phase == 3, not(s.evidence) })
  run evidenceIsSeparateTest = init.then(qualify).then(quote).then(accept)
    .expect(all { invariant, s.phase == 2, not(s.evidence) })
    .then(recordEvidence).expect(all { invariant, s.phase == 2, s.evidence })
  run quoteRevisionTest = init.then(qualify).then(quote).then(quote).then(accept)
    .expect(all { invariant, s.accepted == 2 })
}
