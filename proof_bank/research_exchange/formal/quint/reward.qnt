// One prefunded reward slot, two principals, two generations, and a finite clock.
// Invalid requests are exact no-ops. Trusted verification is an explicit input.
module reward {
  type Binding = { target: int, input: int, environment: int, policy: int }
  type Candidate = { worker: int, generation: int, binding: Binding,
    artifact: int, submittedAt: int, leaseExpires: int }
  type State = { now: int, generation: int, owner: int, expires: int,
    phase: str, admitted: bool, candidate: Candidate, payouts: int,
    escrow: int, balanceA: int, balanceB: int }
  pure val expected = { target: 0, input: 0, environment: 0, policy: 0 }
  pure val bindings = Set(expected, expected.with("target", 1),
    expected.with("input", 1), expected.with("environment", 1), expected.with("policy", 1))
  pure val emptyCandidate = { worker: 0, generation: 0, binding: expected,
    artifact: 0, submittedAt: 0, leaseExpires: 0 }
  pure val initial = { now: 0, generation: 0, owner: 0, expires: 0,
    phase: "open", admitted: false, candidate: emptyCandidate,
    payouts: 0, escrow: 1, balanceA: 0, balanceB: 0 }
  pure def participant(worker: int): bool = worker == 1 or worker == 2

  pure def tick(x: State): State = if (x.now < 2) x.with("now", x.now + 1) else x
  pure def lease(x: State, worker: int, deadline: int): State =
    if (participant(worker) and deadline > x.now and deadline <= 2 and
      x.generation < 2 and not(x.admitted) and
      (x.phase == "open" or (x.phase == "leased" and x.now >= x.expires)))
      x.with("phase", "leased").with("generation", x.generation + 1)
        .with("owner", worker).with("expires", deadline)
    else x

  // The two booleans are explicit mutation switches; production submit fixes both true.
  pure def submitGuarded(x: State, worker: int, generation: int,
      binding: Binding, artifact: int, checkBinding: bool, checkGeneration: bool): State =
    if (x.phase == "leased" and participant(worker) and worker == x.owner and
      (not(checkGeneration) or generation == x.generation) and x.now < x.expires and
      (not(checkBinding) or binding == expected) and not(x.admitted))
      x.with("phase", "submitted").with("admitted", true).with("candidate", {
        worker: worker, generation: generation, binding: binding, artifact: artifact,
        submittedAt: x.now, leaseExpires: x.expires })
    else x
  pure def submit(x: State, worker: int, generation: int, binding: Binding, artifact: int): State =
    submitGuarded(x, worker, generation, binding, artifact, true, true)

  pure def accept(x: State, trusted: bool, evidence: Candidate): State =
    if (x.phase == "submitted" and trusted and x.admitted and evidence == x.candidate and
      evidence.binding == expected and participant(evidence.worker) and
      x.payouts == 0 and x.escrow >= 1)
      x.with("phase", "accepted").with("payouts", 1).with("escrow", x.escrow - 1)
        .with("balanceA", x.balanceA + (if (evidence.worker == 1) 1 else 0))
        .with("balanceB", x.balanceB + (if (evidence.worker == 2) 1 else 0))
    else x

  // Deliberate bad replay edge, bounded at two payouts to keep the mutant finite.
  pure def duplicateAccept(x: State): State =
    if (x.phase == "accepted" and x.payouts < 2)
      x.with("payouts", x.payouts + 1).with("escrow", x.escrow - 1)
        .with("balanceA", x.balanceA + (if (x.candidate.worker == 1) 1 else 0))
        .with("balanceB", x.balanceB + (if (x.candidate.worker == 2) 1 else 0))
    else x

  var s: State
  var immutableCandidate: bool
  var pendingRetainsSlot: bool
  var authorizedPayments: bool
  action observe(after: State, authorized: bool): bool = all {
    immutableCandidate' = (immutableCandidate and
      (if (s.admitted) after.admitted and after.candidate == s.candidate else true)),
    pendingRetainsSlot' = (pendingRetainsSlot and
      (if (s.admitted) after.owner == s.owner and after.generation == s.generation and after.expires == s.expires else true)),
    authorizedPayments' = (authorizedPayments and (after.payouts <= s.payouts or authorized)),
    s' = after,
  }
  action apply(after: State): bool = observe(after, false)
  action decide(trusted: bool, evidence: Candidate): bool =
    observe(accept(s, trusted, evidence), trusted and s.admitted and evidence == s.candidate)
  action init = all { s' = initial, immutableCandidate' = true,
    pendingRetainsSlot' = true, authorizedPayments' = true }
  action tickStep = apply(tick(s))
  action leaseStep = {
    nondet worker = 0.to(2).oneOf()
    nondet deadline = 0.to(2).oneOf()
    apply(lease(s, worker, deadline))
  }
  action submitStep = {
    nondet worker = 0.to(2).oneOf()
    nondet generation = 0.to(2).oneOf()
    nondet binding = bindings.oneOf()
    nondet artifact = Set(0, 1).oneOf()
    apply(submit(s, worker, generation, binding, artifact))
  }
  action acceptStep = {
    nondet trusted = Set(false, true).oneOf()
    nondet evidence = Set(s.candidate, s.candidate.with("artifact", 1 - s.candidate.artifact),
      s.candidate.with("worker", 3 - s.candidate.worker),
      s.candidate.with("generation", 3), s.candidate.with("binding", expected.with("target", 1)),
      s.candidate.with("submittedAt", 3), s.candidate.with("leaseExpires", 3)).oneOf()
    decide(trusted, evidence)
  }
  action step = any { tickStep, leaseStep, submitStep, acceptStep }

  action wrongBindingSubmit =
    apply(submitGuarded(s, s.owner, s.generation, expected.with("target", 1), 0, false, true))
  action staleSubmit = all {
    s.generation == 2,
    apply(submitGuarded(s, s.owner, 1, expected, 0, true, false)),
  }
  action duplicatePaymentStep = any { step, observe(duplicateAccept(s), true) }
  action wrongBindingStep = any { step, wrongBindingSubmit }
  action staleLeaseStep = any { step, staleSubmit }

  val exactBinding = not(s.admitted) or s.candidate.binding == expected
  val freshAdmission = not(s.admitted) or
    (s.candidate.generation == s.generation and s.candidate.worker == s.owner)
  val timelyAdmission = not(s.admitted) or s.candidate.submittedAt < s.candidate.leaseExpires
  val singlePayout = s.payouts <= 1
  val conservation = s.escrow + s.balanceA + s.balanceB == 1
  val nonnegative = s.escrow >= 0 and s.balanceA >= 0 and s.balanceB >= 0
  val acceptedOnlyAdmitted = s.phase != "accepted" or (s.admitted and s.payouts == 1)
  val recipientMatches = (s.balanceA == 0 or (s.admitted and s.candidate.worker == 1)) and
    (s.balanceB == 0 or (s.admitted and s.candidate.worker == 2))
  val safety = exactBinding and freshAdmission and timelyAdmission and singlePayout and
    conservation and nonnegative and acceptedOnlyAdmitted and recipientMatches and
    immutableCandidate and pendingRetainsSlot and authorizedPayments

  run competingWorkersAndDelayedVerificationTest = init
    .then(apply(lease(s, 1, 1))).then(apply(lease(s, 2, 2)))
    .expect(s.owner == 1 and s.generation == 1)
    .then(apply(submit(s, 1, 1, expected, 0))).then(tickStep).then(tickStep)
    .then(apply(lease(s, 2, 2))).expect(s.owner == 1 and s.phase == "submitted")
    .then(decide(true, s.candidate)).then(decide(true, s.candidate))
    .expect(s.phase == "accepted" and s.balanceA == 1 and s.payouts == 1 and safety)
  run staleLeaseCannotSubmitTest = init
    .then(apply(lease(s, 1, 1))).then(tickStep).then(apply(lease(s, 1, 2)))
    .then(apply(submit(s, 1, 1, expected, 0)))
    .expect(not(s.admitted) and s.generation == 2)
    .then(apply(submit(s, 1, 2, expected, 1)))
    .expect(s.admitted and s.candidate.artifact == 1 and safety)
  run exactBindingAndEvidenceTest = init
    .then(apply(lease(s, 2, 2)))
    .then(apply(submit(s, 2, 1, expected.with("target", 1), 0)))
    .then(apply(submit(s, 2, 1, expected.with("input", 1), 0)))
    .then(apply(submit(s, 2, 1, expected.with("environment", 1), 0)))
    .then(apply(submit(s, 2, 1, expected.with("policy", 1), 0)))
    .expect(not(s.admitted))
    .then(apply(submit(s, 2, 1, expected, 0)))
    .then(decide(false, s.candidate))
    .then(decide(true, s.candidate.with("artifact", 1)))
    .expect(s.phase == "submitted" and s.payouts == 0)
    .then(decide(true, s.candidate)).expect(s.balanceB == 1 and safety)
  run expiryBoundaryTest = init
    .then(apply(lease(s, 1, 1))).then(tickStep)
    .then(apply(submit(s, 1, 1, expected, 0))).expect(not(s.admitted))
    .then(apply(lease(s, 2, 2))).then(apply(submit(s, 1, 2, expected, 0)))
    .expect(not(s.admitted) and s.owner == 2 and safety)
}
