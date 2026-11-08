// Independent finite abstraction of the authenticated reward adapter boundary.
// This starts AFTER immutable candidate admission; reward.qnt covers leasing.
// Authentication and controlled checking are premises, not cryptographic proofs.
// Prepared attempts include hostile/invalid records so the committing boundary
// must reject them even if an earlier admission check is absent or defective.
// A profile identifies the entire approved target/source/environment/policy and
// checker configuration. Candidate equality is equality of the complete record.
// Rotation and versionInterference are conservative operator/environment actions;
// neither is a worker HTTP operation. SQL implementation refinement is not proved.
module adapter {
  type Candidate = { worker: int, generation: int, target: int, input: int,
    environment: int, policy: int, artifact: int, submittedAt: int, leaseExpires: int }
  type Prepared = { present: bool, principal: int, authenticated: bool, scoped: bool,
    epoch: int, version: int, candidate: Candidate, profile: int, checked: bool, reject: bool }
  type Durable = { candidate: Candidate, accepted: bool, rejected: bool, version: int,
    enabled: bool, epoch: int, escrow: int, balanceA: int, balanceB: int,
    payouts: int, refunds: int, funder: int, ledgerCount: int, ledgerCandidate: Candidate, receipt: bool }
  type History = { identity: bool, evidence: bool, grant: bool, version: bool,
    retry: bool, refusal: bool }
  type Frame = { d: Durable, originalCandidate: Candidate, a: Prepared, b: Prepared, alive: bool,
    replies: Set[int], history: History }

  // Principals 1 and 2 are distinct workers; 3 is the scoped verifier.
  pure def candidateFor(worker: int): Candidate = { worker: worker, generation: 1,
    target: 0, input: 0, environment: 0, policy: 0, artifact: 0,
    submittedAt: 0, leaseExpires: 1 }
  pure val emptyCandidate = candidateFor(0)
  pure val emptyPrepared = { present: false, principal: 0, authenticated: false,
    scoped: false, epoch: 0, version: 0, candidate: emptyCandidate,
    profile: 0, checked: false, reject: false }
  pure val initialHistory = { identity: true, evidence: true, grant: true,
    version: true, retry: true, refusal: true }
  pure def initial(worker: int): Frame = {
    d: { candidate: candidateFor(worker), accepted: false, rejected: false, version: 0,
      enabled: true, epoch: 0, escrow: 1, balanceA: 0, balanceB: 0,
      payouts: 0, refunds: 0, funder: 0, ledgerCount: 0, ledgerCandidate: emptyCandidate, receipt: false },
    originalCandidate: candidateFor(worker), a: emptyPrepared, b: emptyPrepared, alive: true,
    replies: Set(), history: initialHistory }

  // One representative for each scalar/equality boundary. A wrong candidate may
  // differ in any of its nine fields; none is silently omitted from equality.
  pure val attemptKinds = Set("valid", "reject", "unavailable", "workerA", "workerB", "anonymous",
    "wrongScope", "unchecked", "wrongProfile", "wrongWorker", "wrongGeneration",
    "wrongTarget", "wrongInput", "wrongEnvironment", "wrongPolicy", "wrongArtifact",
    "wrongAdmission", "wrongDeadline")
  pure def snapshot(d: Durable, kind: str): Prepared = {
    val c = d.candidate
    val evidence =
      if (kind == "wrongWorker") c.with("worker", 3 - c.worker)
      else if (kind == "wrongGeneration") c.with("generation", 2)
      else if (kind == "wrongTarget") c.with("target", 1)
      else if (kind == "wrongInput") c.with("input", 1)
      else if (kind == "wrongEnvironment") c.with("environment", 1)
      else if (kind == "wrongPolicy") c.with("policy", 1)
      else if (kind == "wrongArtifact") c.with("artifact", 1)
      else if (kind == "wrongAdmission") c.with("submittedAt", 1)
      else if (kind == "wrongDeadline") c.with("leaseExpires", 2)
      else c
    { present: true,
      principal: if (kind == "workerA") 1 else if (kind == "workerB") 2 else 3,
      authenticated: kind != "anonymous", scoped: kind != "wrongScope",
      epoch: d.epoch, version: d.version, candidate: evidence,
      profile: if (kind == "wrongProfile") 1 else 0,
      checked: kind != "unchecked" and kind != "unavailable",
      reject: Set("reject", "unavailable").contains(kind) }
  }
  pure def operation(x: Frame, id: int): Prepared = if (id == 1) x.a else x.b
  pure def identityOK(p: Prepared): bool =
    p.authenticated and p.principal == 3 and p.scoped
  pure def grantOK(d: Durable, p: Prepared): bool = d.enabled and p.epoch == d.epoch
  pure def evidenceOK(d: Durable, p: Prepared): bool =
    p.checked and p.profile == 0 and p.candidate == d.candidate
  pure def terminal(d: Durable): bool = d.accepted or d.rejected
  pure def eligible(d: Durable, p: Prepared): bool =
    p.present and identityOK(p) and grantOK(d, p) and evidenceOK(d, p) and
    p.version == d.version and not(terminal(d)) and d.payouts == 0 and
    d.ledgerCount == 0 and not(d.receipt) and d.escrow == 1

  pure def prepare(x: Frame, id: int, kind: str): Frame =
    if (x.alive) {
      val p = snapshot(x.d, kind)
      val waiting = x.with("replies", x.replies.exclude(Set(id)))
      if (id == 1) waiting.with("a", p) else waiting.with("b", p)
    } else x

  // Closure makes the balances, ledger and durable receipt visible together. Replies are outside the durable record.
  pure def pay(d: Durable, p: Prepared): Durable =
    d.with("accepted", true).with("version", d.version + 1)
      .with("escrow", d.escrow - 1).with("payouts", d.payouts + 1)
      .with("balanceA", d.balanceA + (if (d.candidate.worker == 1) 1 else 0))
      .with("balanceB", d.balanceB + (if (d.candidate.worker == 2) 1 else 0))
      .with("ledgerCount", d.ledgerCount + 1).with("ledgerCandidate", p.candidate)
      .with("receipt", true)

  pure def refund(d: Durable, p: Prepared): Durable =
    d.with("rejected", true).with("version", d.version + 1)
      .with("escrow", 0).with("funder", d.funder + d.escrow).with("refunds", d.refunds + 1)
      .with("ledgerCount", d.ledgerCount + 1).with("ledgerCandidate", p.candidate)
      .with("receipt", true)

  // Mutation switches are used ONLY by named negative-control step relations.
  // A counterexample tests the stated property, not equivalence to a code patch.
  pure def commit(x: Frame, id: int, mutation: str, deliver: bool): Frame = {
    val d = x.d
    val p = operation(x, id)
    val identity = mutation == "authority" or identityOK(p)
    val grant = (mutation == "grant" or d.enabled) and
      (mutation == "grant" or mutation == "epoch" or p.epoch == d.epoch)
    val checked = mutation == "unchecked" or (mutation == "timeout" and p.reject) or p.checked
    val profile = mutation == "profile" or p.profile == 0
    val candidate = mutation == "candidate" or p.candidate == d.candidate
    val version = mutation == "version" or p.version == d.version
    val authorized = x.alive and p.present and identity and grant
    val fresh = authorized and checked and profile and candidate and version and
      not(terminal(d)) and d.payouts == 0 and d.ledgerCount == 0 and not(d.receipt) and d.escrow == 1
    val retry = authorized and terminal(d) and d.receipt
    val duplicate = mutation == "duplicate" and retry and d.payouts < 2
    val duplicateRefund = mutation == "duplicateRefund" and retry and d.rejected
    val overwrite = mutation == "overwriteRejected" and retry and d.rejected and not(p.reject)
    val nextDurable = if (fresh or duplicate or duplicateRefund or overwrite) {
      val paid = if (p.reject) refund(d, p) else pay(d, p)
      if (mutation == "split")
        paid.with("ledgerCount", d.ledgerCount).with("ledgerCandidate", d.ledgerCandidate)
          .with("receipt", d.receipt)
      else paid
    } else d
    val returned = deliver and (fresh or retry)
    val increased = nextDurable.payouts > d.payouts or nextDurable.refunds > d.refunds
    val nextHistory = {
      identity: x.history.identity and (not(increased or returned) or identityOK(p)),
      evidence: x.history.evidence and (not(increased) or evidenceOK(d, p)),
      grant: x.history.grant and (not(increased or returned) or grantOK(d, p)),
      version: x.history.version and (not(increased) or p.version == d.version),
      retry: x.history.retry and (not(terminal(d)) or nextDurable == d),
      refusal: x.history.refusal and
        (not(x.alive and p.present and not(terminal(d)) and not(eligible(d, p))) or nextDurable == d)
    }
    x.with("d", nextDurable).with("history", nextHistory)
      .with("replies", if (returned) x.replies.union(Set(id)) else x.replies)
  }

  // An actual process death loses prepared work and delivery observations only.
  // Calling this before commit persists neither update; after commit persists both.
  pure def crash(x: Frame): Frame =
    x.with("alive", false).with("a", emptyPrepared).with("b", emptyPrepared)
      .with("replies", Set())
  pure def restart(x: Frame): Frame = x.with("alive", true)
  pure def loseResponse(x: Frame): Frame = x.with("replies", Set())
  pure def revoke(x: Frame): Frame =
    if (x.d.enabled and x.d.epoch < 2)
      x.with("d", x.d.with("enabled", false).with("epoch", x.d.epoch + 1)) else x
  pure def rotate(x: Frame): Frame =
    if (x.d.epoch < 2)
      x.with("d", x.d.with("enabled", true).with("epoch", x.d.epoch + 1)) else x
  pure def interfere(x: Frame): Frame =
    if (not(terminal(x.d)) and x.d.version == 0)
      x.with("d", x.d.with("version", 1)) else x

  var m: Frame
  action apply(after: Frame): bool = m' = after
  action init = { nondet worker = Set(1, 2).oneOf(); m' = initial(worker) }
  action initA = m' = initial(1)
  action prepareStep = {
    nondet id = Set(1, 2).oneOf()
    nondet kind = attemptKinds.oneOf()
    apply(prepare(m, id, kind))
  }
  action commitStep = {
    nondet id = Set(1, 2).oneOf()
    nondet deliver = Set(false, true).oneOf()
    apply(commit(m, id, "none", deliver))
  }
  action crashBeforeCommit = apply(crash(m))
  action crashAfterCommit = {
    nondet id = Set(1, 2).oneOf()
    apply(crash(commit(m, id, "none", false)))
  }
  action restartStep = apply(restart(m))
  action lostResponse = apply(loseResponse(m))
  action revokeStep = apply(revoke(m))
  action rotateStep = apply(rotate(m))
  action versionInterference = apply(interfere(m))
  action step = any { prepareStep, commitStep, crashBeforeCommit, crashAfterCommit,
    restartStep, lostResponse, revokeStep, rotateStep, versionInterference }

  action faultyCommit(mutation: str): bool = {
    nondet id = Set(1, 2).oneOf()
    apply(commit(m, id, mutation, true))
  }
  action unauthorizedStep = any { step, faultyCommit("authority") }
  action uncheckedStep = any { step, faultyCommit("unchecked") }
  action wrongProfileStep = any { step, faultyCommit("profile") }
  action wrongCandidateStep = any { step, faultyCommit("candidate") }
  action staleEpochStep = any { step, faultyCommit("epoch") }
  action revokedGrantStep = any { step, faultyCommit("grant") }
  action staleVersionStep = any { step, faultyCommit("version") }
  action splitWriteStep = any { step, faultyCommit("split") }
  action duplicatePaymentStep = any { step, faultyCommit("duplicate") }
  action timeoutRefundStep = any { step, faultyCommit("timeout") }
  action duplicateRefundStep = any { step, faultyCommit("duplicateRefund") }
  action overwriteRejectedStep = any { step, faultyCommit("overwriteRejected") }

  val authorizedEffects = m.history.identity
  val checkedExactEvidence = m.history.evidence
  val currentGrantOnly = m.history.grant
  val currentVersionOnly = m.history.version
  val retryPreservesDurable = m.history.retry
  val invalidPreservesDurable = m.history.refusal
  val singlePayout = m.d.payouts <= 1
  val singleRefund = m.d.refunds <= 1
  val exclusiveClosure = m.d.payouts + m.d.refunds <= 1 and not(m.d.accepted and m.d.rejected)
  val atomicSettlement = m.d.payouts + m.d.refunds == m.d.ledgerCount and
    m.d.accepted == (m.d.payouts == 1) and m.d.rejected == (m.d.refunds == 1) and
    m.d.receipt == terminal(m.d)
  val exactSettlement = m.d.ledgerCount == 0 or m.d.ledgerCandidate == m.d.candidate
  val conservation = m.d.escrow + m.d.balanceA + m.d.balanceB + m.d.funder == 1 and
    m.d.funder == m.d.refunds
  val nonnegative = m.d.escrow >= 0 and m.d.balanceA >= 0 and m.d.balanceB >= 0
  val correctRecipient = (m.d.balanceA == 0 or m.d.candidate.worker == 1) and
    (m.d.balanceB == 0 or m.d.candidate.worker == 2)
  val immutableCandidate = m.d.candidate == m.originalCandidate and
    Set(1, 2).contains(m.d.candidate.worker)
  val responsesHaveReceipt = m.replies.size() == 0 or
    (m.d.receipt and m.d.ledgerCount == 1 and terminal(m.d))
  val bounded = m.d.version >= 0 and m.d.version <= 2 and
    m.d.epoch >= 0 and m.d.epoch <= 2
  val safety = authorizedEffects and checkedExactEvidence and currentGrantOnly and
    currentVersionOnly and retryPreservesDurable and invalidPreservesDurable and
    singlePayout and singleRefund and exclusiveClosure and atomicSettlement and exactSettlement and conservation and
    nonnegative and correctRecipient and immutableCandidate and responsesHaveReceipt and bounded

  run forgedWorkerAndAnonymousTest = initA
    .then(apply(prepare(m, 1, "workerA"))).then(apply(commit(m, 1, "none", true)))
    .then(apply(prepare(m, 2, "workerB"))).then(apply(commit(m, 2, "none", true)))
    .then(apply(prepare(m, 1, "anonymous"))).then(apply(commit(m, 1, "none", true)))
    .then(apply(prepare(m, 2, "wrongScope"))).then(apply(commit(m, 2, "none", true)))
    .expect(m.d.payouts == 0 and m.replies.size() == 0 and safety)
  run uncheckedAndWrongTargetTest = initA
    .then(apply(prepare(m, 1, "unchecked"))).then(apply(commit(m, 1, "none", true)))
    .then(apply(prepare(m, 1, "wrongTarget"))).then(apply(commit(m, 1, "none", true)))
    .then(apply(prepare(m, 2, "wrongProfile"))).then(apply(commit(m, 2, "none", true)))
    .expect(m.d.payouts == 0 and m.d.ledgerCount == 0 and safety)
  run competingPreparedAttemptsTest = initA
    .then(apply(prepare(m, 1, "valid"))).then(apply(prepare(m, 2, "valid")))
    .then(apply(commit(m, 1, "none", true))).then(apply(commit(m, 2, "none", true)))
    .expect(m.d.payouts == 1 and m.d.ledgerCount == 1 and m.d.receipt and
      m.replies == Set(1, 2) and m.d.version == 1 and safety)
  run revocationDuringCheckingTest = initA
    .then(apply(prepare(m, 1, "valid"))).then(revokeStep)
    .then(apply(commit(m, 1, "none", true)))
    .expect(not(m.d.enabled) and m.d.payouts == 0 and safety)
  run epochRotationFencesOldCheckTest = initA
    .then(apply(prepare(m, 1, "valid"))).then(rotateStep)
    .then(apply(commit(m, 1, "none", true)))
    .expect(m.d.enabled and m.d.epoch == 1 and m.d.payouts == 0)
    .then(apply(prepare(m, 2, "valid"))).then(apply(commit(m, 2, "none", true)))
    .expect(m.d.payouts == 1 and m.replies == Set(2) and safety)
  run versionFenceWithImmutableCandidateTest = initA
    .then(apply(prepare(m, 1, "valid"))).then(versionInterference)
    .then(apply(commit(m, 1, "none", true)))
    .expect(m.d.payouts == 0 and m.d.candidate == candidateFor(1))
    .then(apply(prepare(m, 2, "valid"))).then(apply(commit(m, 2, "none", true)))
    .expect(m.d.payouts == 1 and m.d.version == 2 and safety)
  run crashBeforeCommitTest = initA
    .then(apply(prepare(m, 1, "valid"))).then(crashBeforeCommit)
    .expect(not(m.alive) and not(m.d.accepted) and m.d.ledgerCount == 0 and not(m.d.receipt))
    .then(restartStep).then(apply(prepare(m, 1, "valid")))
    .then(apply(commit(m, 1, "none", true)))
    .expect(m.d.payouts == 1 and m.d.ledgerCount == 1 and safety)
  run crashAfterCommitBeforeResponseTest = initA
    .then(apply(prepare(m, 1, "valid")))
    .then(apply(crash(commit(m, 1, "none", false))))
    .expect(not(m.alive) and m.d.payouts == 1 and m.d.ledgerCount == 1 and m.d.receipt and m.replies.size() == 0)
    .then(restartStep).then(apply(prepare(m, 1, "valid")))
    .then(apply(commit(m, 1, "none", true)))
    .expect(m.replies == Set(1) and m.d.payouts == 1 and m.d.version == 1 and safety)
  run lostResponseRetryTest = initA
    .then(apply(prepare(m, 1, "valid"))).then(apply(commit(m, 1, "none", false)))
    .expect(m.d.receipt and m.replies.size() == 0)
    .then(apply(commit(m, 1, "none", true))).then(lostResponse)
    .then(apply(commit(m, 1, "none", true)))
    .expect(m.replies == Set(1) and m.d.payouts == 1 and m.d.ledgerCount == 1 and safety)
  run revokedRetryCannotReturnReceiptTest = initA
    .then(apply(prepare(m, 1, "valid"))).then(apply(commit(m, 1, "none", false)))
    .then(revokeStep).then(apply(commit(m, 1, "none", true)))
    .expect(m.d.receipt and m.replies.size() == 0 and m.d.payouts == 1 and safety)

  run duplicateRejectionsTest = initA
    .then(apply(prepare(m, 1, "reject"))).then(apply(prepare(m, 2, "reject")))
    .then(apply(commit(m, 1, "none", true))).then(apply(commit(m, 2, "none", true)))
    .expect(m.d.rejected and m.d.refunds == 1 and m.d.funder == 1 and
      m.d.version == 1 and m.replies == Set(1, 2) and safety)
  run rejectionFencesStaleAcceptanceTest = initA
    .then(apply(prepare(m, 1, "valid"))).then(apply(prepare(m, 2, "reject")))
    .then(apply(commit(m, 2, "none", true))).then(apply(commit(m, 1, "none", true)))
    .expect(m.d.rejected and m.d.payouts == 0 and m.d.refunds == 1 and safety)
  run acceptanceFencesStaleRejectionTest = initA
    .then(apply(prepare(m, 1, "valid"))).then(apply(prepare(m, 2, "reject")))
    .then(apply(commit(m, 1, "none", true))).then(apply(commit(m, 2, "none", true)))
    .expect(m.d.accepted and m.d.payouts == 1 and m.d.refunds == 0 and safety)
  run unavailableAndRevokedRejectionTest = initA
    .then(apply(prepare(m, 1, "unavailable"))).then(apply(commit(m, 1, "none", true)))
    .then(apply(prepare(m, 2, "reject"))).then(revokeStep)
    .then(apply(commit(m, 2, "none", true))).then(rotateStep)
    .then(apply(commit(m, 2, "none", true)))
    .expect(m.d.escrow == 1 and m.d.refunds == 0 and m.replies == Set() and safety)
  run stalePreparedRejectionTest = initA
    .then(apply(prepare(m, 1, "reject"))).then(versionInterference)
    .then(apply(commit(m, 1, "none", true)))
    .expect(m.d.escrow == 1 and m.d.refunds == 0 and safety)
  run rejectionCrashBeforeTest = initA
    .then(apply(prepare(m, 1, "reject"))).then(crashBeforeCommit)
    .expect(not(m.alive) and m.d.escrow == 1 and m.d.refunds == 0 and not(m.d.receipt))
    .then(restartStep).then(apply(prepare(m, 1, "reject")))
    .then(apply(commit(m, 1, "none", true)))
    .expect(m.d.refunds == 1 and m.d.receipt and safety)
  run rejectionCrashAfterTest = initA
    .then(apply(prepare(m, 1, "reject")))
    .then(apply(crash(commit(m, 1, "none", false))))
    .expect(not(m.alive) and m.d.rejected and m.d.refunds == 1 and m.replies == Set())
    .then(restartStep).then(apply(prepare(m, 1, "reject")))
    .then(apply(commit(m, 1, "none", true)))
    .expect(m.d.version == 1 and m.d.refunds == 1 and m.replies == Set(1) and safety)
}
