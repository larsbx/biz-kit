// Independent finite specification of the durable MCP bridge transaction boundary.
// This is not generated from, imported by, or a refinement proof of the runtime.
// Checking is outside the transaction: a prepared result may race every fence.
// Source abstracts the whole library/revision/snapshot/core identity; the other
// binding components have separate equality representatives. One checking worker
// may present a substituted record; a second worker supplies an exact record.
module bridge {
  type Binding = { owner: int, source: int, target: int, artifact: int,
    environment: int, policy: int }
  type Prepared = { present: bool, verifier: int, requesterEpoch: int,
    verifierEpoch: int, version: int, profile: int, binding: Binding, verdict: int }
  // outbox: 0 absent, 1 pending, 2 paused, 3 delivered.
  // terminal/receipt: 0 absent, 1 accepted, 2 rejected. Verdict 3 is inconclusive.
  type Durable = { submission: bool, job: bool, binding: Binding,
    jobBinding: Binding, outbox: int, terminal: int, receipt: int,
    receiptBinding: Binding, effects: int, version: int, retried: bool,
    interfered: bool }
  type Grants = { requesterEnabled: bool, requesterEpoch: int,
    verifierEnabled: bool, verifierEpoch: int, profile: int }
  type History = { requester: bool, verifier: bool, version: bool,
    profile: bool, definitive: bool, refusal: bool, inconclusive: bool,
    operatorRetry: bool, reads: bool, retries: bool, crash: bool }
  type State = { d: Durable, g: Grants, a: Prepared, b: Prepared,
    alive: bool, reply: int, winner: int, h: History }

  pure val admittedBinding: Binding = { owner: 1, source: 0, target: 0,
    artifact: 0, environment: 0, policy: 0 }
  pure val absent: Prepared = { present: false, verifier: 0,
    requesterEpoch: 0, verifierEpoch: 0, version: 0, profile: 0,
    binding: admittedBinding, verdict: 0 }
  pure val initial: State = {
    d: { submission: false, job: false, binding: admittedBinding,
      jobBinding: admittedBinding, outbox: 0, terminal: 0, receipt: 0,
      receiptBinding: admittedBinding, effects: 0, version: 0,
      retried: false, interfered: false },
    g: { requesterEnabled: true, requesterEpoch: 0,
      verifierEnabled: true, verifierEpoch: 0, profile: 0 },
    a: absent, b: absent, alive: true, reply: 0, winner: 0,
    h: { requester: true, verifier: true, version: true, profile: true,
      definitive: true, refusal: true, inconclusive: true,
      operatorRetry: true, reads: true, retries: true, crash: true }
  }

  pure def terminal(d: Durable): bool = d.terminal != 0
  pure def formal(d: Durable): (bool, int, int, int) =
    (d.submission, d.terminal, d.effects, d.version)
  pure def preparedFor(x: State, id: int): Prepared = if (id == 1) x.a else x.b
  pure def withPrepared(x: State, id: int, p: Prepared): State =
    if (id == 1) x.with("a", p) else x.with("b", p)

  pure def admit(x: State, mutation: str): State =
    if (x.alive and not(x.d.submission) and x.g.requesterEnabled) {
      val d = x.d.with("submission", true).with("job", true)
        .with("outbox", if (mutation == "admission") 0 else 1)
      x.with("d", d)
    } else x

  pure def substituted(kind: int): Binding =
    if (kind == 1) admittedBinding.with("source", 1)
    else if (kind == 2) admittedBinding.with("target", 1)
    else if (kind == 3) admittedBinding.with("artifact", 1)
    else if (kind == 4) admittedBinding.with("environment", 1)
    else if (kind == 5) admittedBinding.with("policy", 1)
    else if (kind == 6) admittedBinding.with("owner", 2)
    else admittedBinding

  pure def prepare(x: State, id: int, kind: int, verdict: int): State =
    if (x.alive and x.d.job and x.d.outbox == 1 and not(terminal(x.d))
        and not(preparedFor(x, id).present)) {
      val p: Prepared = { present: true, verifier: if (kind == 7) 2 else 3,
        requesterEpoch: x.g.requesterEpoch, verifierEpoch: x.g.verifierEpoch,
        version: x.d.version, profile: if (kind == 8) 1 - x.g.profile else x.g.profile,
        binding: substituted(kind), verdict: verdict }
      withPrepared(x, id, p)
    } else x

  pure def requesterOK(x: State, p: Prepared): bool =
    x.g.requesterEnabled and p.requesterEpoch == x.g.requesterEpoch
  pure def verifierOK(x: State, p: Prepared): bool =
    p.verifier == 3 and x.g.verifierEnabled and p.verifierEpoch == x.g.verifierEpoch
  pure def bindingOK(d: Durable, p: Prepared, mutation: str): bool =
    (mutation == "source" or p.binding.source == d.binding.source) and
    (mutation == "target" or p.binding.target == d.binding.target) and
    (mutation == "artifact" or p.binding.artifact == d.binding.artifact) and
    (mutation == "environment" or p.binding.environment == d.binding.environment) and
    (mutation == "policy" or p.binding.policy == d.binding.policy) and
    (mutation == "owner" or p.binding.owner == d.binding.owner)
  pure def fences(x: State, p: Prepared, mutation: str): bool =
    (mutation == "requesterGrant" or x.g.requesterEnabled) and
    (mutation == "requesterEpoch" or p.requesterEpoch == x.g.requesterEpoch) and
    (mutation == "verifierAuthority" or p.verifier == 3) and
    (mutation == "verifierGrant" or x.g.verifierEnabled) and
    (mutation == "verifierEpoch" or p.verifierEpoch == x.g.verifierEpoch) and
    (mutation == "version" or p.version == x.d.version) and
    (mutation == "profile" or p.profile == x.g.profile) and
    bindingOK(x.d, p, mutation)
  pure def eligible(x: State, p: Prepared): bool =
    x.alive and p.present and x.d.job and Set(1, 2).contains(x.d.outbox) and
    not(terminal(x.d)) and x.d.effects == 0 and fences(x, p, "none") and
    Set(1, 2).contains(p.verdict)

  pure def commit(x: State, id: int, mutation: str): State = {
    val p = preparedFor(x, id)
    val current = x.alive and p.present and x.d.job and fences(x, p, mutation)
    val definitive = Set(1, 2).contains(p.verdict)
    val fresh = current and Set(1, 2).contains(x.d.outbox) and not(terminal(x.d)) and
      x.d.effects == 0 and (definitive or (mutation == "inconclusive" and p.verdict == 3))
    val duplicate = mutation == "duplicate" and x.alive and p.present and
      terminal(x.d) and definitive and x.d.effects < 2
    val overwrite = mutation == "overwrite" and x.alive and p.present and
      terminal(x.d) and definitive and p.verdict != x.d.terminal
    val changed = fresh or duplicate or overwrite
    val decision = if (p.verdict == 3) 2 else p.verdict
    val d = if (changed) x.d.with("terminal", decision)
      .with("receipt", if (mutation == "publication") x.d.receipt else decision)
      .with("receiptBinding", p.binding)
      .with("outbox", if (mutation == "publication") x.d.outbox else 3)
      .with("effects", if (overwrite) x.d.effects else x.d.effects + 1)
      .with("version", if (fresh) x.d.version + 1 else x.d.version)
      else x.d
    val h = x.h
      .with("requester", x.h.requester and (not(changed) or requesterOK(x, p)))
      .with("verifier", x.h.verifier and (not(changed) or verifierOK(x, p)))
      .with("version", x.h.version and (not(changed) or p.version == x.d.version))
      .with("profile", x.h.profile and (not(changed) or p.profile == x.g.profile))
      .with("definitive", x.h.definitive and (not(changed) or definitive))
      .with("refusal", x.h.refusal and (eligible(x, p) or d == x.d))
    x.with("d", d).with("h", h)
      .with("winner", if (x.winner == 0 and changed) decision else x.winner)
  }

  // Inconclusive checking only pauses dispatch metadata; it cannot alter the
  // represented formal state. One explicit operator retry is in the finite scope.
  pure def pause(x: State, id: int, mutation: str): State = {
    val p = preparedFor(x, id)
    val ready = x.alive and p.present and p.verdict == 3 and x.d.job and
      x.d.outbox == 1 and not(terminal(x.d)) and fences(x, p, "none")
    val d = if (ready) x.d.with("outbox", 2)
      .with("version", if (mutation == "pauseVersion") x.d.version + 1 else x.d.version)
      .with("terminal", if (mutation == "pauseEffect") 2 else x.d.terminal) else x.d
    val y = x.with("d", d)
      .with("h", x.h.with("inconclusive", x.h.inconclusive and formal(d) == formal(x.d)))
    // The completed inconclusive attempt releases its own slot. Competing
    // prepared results remain available; dispatch pause does not invalidate them.
    if (ready) withPrepared(y, id, absent) else y
  }
  pure def operatorRetry(x: State, mutation: str): State = {
    val ready = x.alive and x.d.outbox == 2 and not(x.d.retried)
    val d = if (ready) x.d.with("outbox", 1).with("retried", true)
      .with("version", if (mutation == "retryVersion") x.d.version + 1 else x.d.version) else x.d
    x.with("d", d).with("h", x.h.with("operatorRetry",
      x.h.operatorRetry and formal(d) == formal(x.d)))
  }
  pure def crash(x: State, mutation: str): State = {
    val d = if (mutation == "crash" and x.d.outbox == 1) x.d.with("outbox", 0) else x.d
    x.with("d", d).with("alive", false).with("a", absent).with("b", absent)
      .with("reply", 0).with("h", x.h.with("crash", x.h.crash and d == x.d))
  }
  pure def restart(x: State): State = x.with("alive", true)
  pure def requesterRevoke(x: State): State =
    if (x.g.requesterEnabled and x.g.requesterEpoch == 0)
      x.with("g", x.g.with("requesterEnabled", false).with("requesterEpoch", 1)) else x
  pure def requesterRegrant(x: State): State =
    if (not(x.g.requesterEnabled) and x.g.requesterEpoch == 1)
      x.with("g", x.g.with("requesterEnabled", true).with("requesterEpoch", 2)) else x
  pure def verifierRevoke(x: State): State =
    if (x.g.verifierEnabled and x.g.verifierEpoch == 0)
      x.with("g", x.g.with("verifierEnabled", false).with("verifierEpoch", 1)) else x
  pure def verifierRegrant(x: State): State =
    if (not(x.g.verifierEnabled) and x.g.verifierEpoch == 1)
      x.with("g", x.g.with("verifierEnabled", true).with("verifierEpoch", 2)) else x
  pure def rotateProfile(x: State): State = x.with("g", x.g.with("profile", 1))
  pure def interfere(x: State): State =
    if (x.d.job and not(terminal(x.d)) and not(x.d.interfered))
      x.with("d", x.d.with("version", x.d.version + 1).with("interfered", true)) else x
  pure def readReceipt(x: State, principal: int, retry: bool, mutation: str): State = {
    val authorized = principal == x.d.binding.owner and x.g.requesterEnabled
    val returned = x.alive and x.d.job and
      (authorized or (mutation == "readScope" and not(retry)) or (mutation == "retryScope" and retry))
    val h = if (retry) x.h.with("retries", x.h.retries and (not(returned) or authorized))
      else x.h.with("reads", x.h.reads and (not(returned) or authorized))
    x.with("h", h).with("reply", if (returned and terminal(x.d))
      (if (mutation == "wrongReply") 3 - x.d.receipt else x.d.receipt) else x.reply)
  }

  var m: State
  action apply(after: State): bool = m' = after
  action init = m' = initial
  action admitStep = apply(admit(m, "none"))
  action prepareStep = {
    nondet id = Set(1, 2).oneOf()
    nondet kind = (if (id == 1) 0.to(8) else Set(0)).oneOf()
    nondet verdict = Set(1, 2, 3).oneOf()
    apply(prepare(m, id, kind, verdict))
  }
  action finishStep = { nondet id = Set(1, 2).oneOf(); apply(commit(m, id, "none")) }
  action pauseStep = { nondet id = Set(1, 2).oneOf(); apply(pause(m, id, "none")) }
  action crashStep = apply(crash(m, "none"))
  action restartStep = apply(restart(m))
  action requesterRevokeStep = apply(requesterRevoke(m))
  action requesterRegrantStep = apply(requesterRegrant(m))
  action verifierRevokeStep = apply(verifierRevoke(m))
  action verifierRegrantStep = apply(verifierRegrant(m))
  action profileStep = apply(rotateProfile(m))
  action interferenceStep = apply(interfere(m))
  action retryStep = apply(operatorRetry(m, "none"))
  action readStep = {
    nondet principal = Set(1, 2).oneOf()
    nondet retry = Set(false, true).oneOf()
    apply(readReceipt(m, principal, retry, "none"))
  }
  action step = any { admitStep, prepareStep, finishStep, pauseStep, crashStep,
    restartStep, requesterRevokeStep, requesterRegrantStep, verifierRevokeStep,
    verifierRegrantStep, profileStep, interferenceStep, retryStep, readStep }
  action faulty(mutation: str): bool = { nondet id = Set(1, 2).oneOf(); apply(commit(m, id, mutation)) }
  action splitAdmissionStep = any { step, apply(admit(m, "admission")) }
  action sourceStep = any { step, faulty("source") }
  action targetStep = any { step, faulty("target") }
  action artifactStep = any { step, faulty("artifact") }
  action environmentStep = any { step, faulty("environment") }
  action policyStep = any { step, faulty("policy") }
  action ownerStep = any { step, faulty("owner") }
  action requesterGrantStep = any { step, faulty("requesterGrant") }
  action requesterEpochStep = any { step, faulty("requesterEpoch") }
  action verifierAuthorityStep = any { step, faulty("verifierAuthority") }
  action verifierGrantStep = any { step, faulty("verifierGrant") }
  action verifierEpochStep = any { step, faulty("verifierEpoch") }
  action versionStep = any { step, faulty("version") }
  action wrongProfileStep = any { step, faulty("profile") }
  action publicationStep = any { step, faulty("publication") }
  action duplicateStep = any { step, faulty("duplicate") }
  action overwriteStep = any { step, faulty("overwrite") }
  action inconclusiveStep = any { step, faulty("inconclusive") }
  action lostOutboxStep = any { step, apply(crash(m, "crash")) }
  action unauthorizedReadStep = any { step, apply(readReceipt(m, 2, false, "readScope")) }
  action unauthorizedRetryStep = any { step, apply(readReceipt(m, 2, true, "retryScope")) }
  action inconclusiveEffectStep = any { step, apply(pause(m, 1, "pauseEffect")) }
  action inconclusiveVersionStep = any { step, apply(pause(m, 1, "pauseVersion")) }
  action retryEffectStep = any { step, apply(operatorRetry(m, "retryVersion")) }
  action wrongReplyStep = any { step, apply(readReceipt(m, 1, true, "wrongReply")) }
  action unboundedVersionStep = any { step,
    apply(if (m.d.job and not(terminal(m.d)))
      m.with("d", m.d.with("version", m.d.version + 1)) else m) }
  action replacedSubmissionStep = any { step,
    apply(if (m.d.submission) m.with("d", m.d.with("binding", substituted(3))) else m) }

  val atomicAdmission = m.d.submission == m.d.job and m.d.job == (m.d.outbox != 0)
  val immutableAdmission = not(m.d.submission) or
    (m.d.binding == admittedBinding and m.d.jobBinding == admittedBinding)
  val atomicPublication = terminal(m.d) == (m.d.outbox == 3) and
    m.d.receipt == m.d.terminal and m.d.effects == (if (terminal(m.d)) 1 else 0)
  val exactEvidence = not(terminal(m.d)) or m.d.receiptBinding == m.d.binding
  val oneEffect = m.d.effects <= 1
  val terminalImmutable = m.winner == 0 or m.d.terminal == m.winner
  val requesterAuthority = m.h.requester
  val verifierAuthority = m.h.verifier
  val currentVersion = m.h.version
  val currentProfile = m.h.profile
  val definitiveOnly = m.h.definitive
  val refusalsInert = m.h.refusal
  val inconclusiveInert = m.h.inconclusive
  val operatorRetryInert = m.h.operatorRetry
  val ownerReads = m.h.reads
  val ownerRetries = m.h.retries
  val crashDurable = m.h.crash
  val durableReplies = m.reply == 0 or (terminal(m.d) and m.reply == m.d.receipt)
  val bounded = m.d.version >= 0 and m.d.version <= 2 and
    m.g.requesterEpoch >= 0 and m.g.requesterEpoch <= 2 and
    m.g.verifierEpoch >= 0 and m.g.verifierEpoch <= 2
  val safety = atomicAdmission and immutableAdmission and atomicPublication and
    exactEvidence and oneEffect and terminalImmutable and requesterAuthority and
    verifierAuthority and currentVersion and currentProfile and definitiveOnly and
    refusalsInert and inconclusiveInert and operatorRetryInert and ownerReads and ownerRetries and
    crashDurable and durableReplies and bounded

  run acceptedTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 1))).then(apply(commit(m, 1, "none")))
    .expect(m.d.terminal == 1 and m.d.effects == 1 and safety)
  run rejectedTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 2))).then(apply(commit(m, 1, "none")))
    .expect(m.d.terminal == 2 and m.d.effects == 1 and safety)
  run competingWorkersTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 1))).then(apply(prepare(m, 2, 0, 1)))
    .then(apply(commit(m, 1, "none"))).then(apply(commit(m, 2, "none")))
    .expect(m.d.terminal == 1 and m.d.effects == 1 and safety)
  run rejectionWinsTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 1))).then(apply(prepare(m, 2, 0, 2)))
    .then(apply(commit(m, 2, "none"))).then(apply(commit(m, 1, "none")))
    .expect(m.d.terminal == 2 and m.d.effects == 1 and safety)
  run acceptanceWinsTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 1))).then(apply(prepare(m, 2, 0, 2)))
    .then(apply(commit(m, 1, "none"))).then(apply(commit(m, 2, "none")))
    .expect(m.d.terminal == 1 and m.d.effects == 1 and safety)
  run requesterRevokedTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 1))).then(requesterRevokeStep)
    .then(apply(commit(m, 1, "none"))).expect(m.d.effects == 0 and safety)
  run requesterRegrantFencesTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 1))).then(requesterRevokeStep).then(requesterRegrantStep)
    .then(apply(commit(m, 1, "none"))).expect(m.d.effects == 0)
    .then(apply(prepare(m, 2, 0, 1))).then(apply(commit(m, 2, "none")))
    .expect(m.d.effects == 1 and safety)
  run verifierRegrantFencesTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 2))).then(verifierRevokeStep).then(verifierRegrantStep)
    .then(apply(commit(m, 1, "none"))).expect(m.d.effects == 0)
    .then(apply(prepare(m, 2, 0, 2))).then(apply(commit(m, 2, "none")))
    .expect(m.d.effects == 1 and m.d.terminal == 2 and safety)
  run staleVersionTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 1))).then(interferenceStep)
    .then(apply(commit(m, 1, "none"))).expect(m.d.effects == 0 and safety)
  run staleProfileTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 1))).then(profileStep)
    .then(apply(commit(m, 1, "none"))).expect(m.d.effects == 0 and safety)
  run substitutedSourceTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 1, 1))).then(apply(commit(m, 1, "none")))
    .expect(m.d.effects == 0 and safety)
  run substitutedTargetTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 2, 1))).then(apply(commit(m, 1, "none")))
    .expect(m.d.effects == 0 and safety)
  run substitutedArtifactTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 3, 2))).then(apply(commit(m, 1, "none")))
    .expect(m.d.effects == 0 and safety)
  run inconclusivePauseRetryTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 3))).then(apply(pause(m, 1, "none")))
    .expect(m.d.outbox == 2 and m.d.terminal == 0 and m.d.effects == 0)
    .then(retryStep).then(apply(prepare(m, 2, 0, 1))).then(apply(commit(m, 2, "none")))
    .expect(m.d.terminal == 1 and m.d.effects == 1 and safety)
  run inconclusivePreservesCurrentCheckTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 3))).then(apply(prepare(m, 2, 0, 1)))
    .then(apply(pause(m, 1, "none")))
    .expect(m.d.outbox == 2 and m.d.version == 0 and m.d.effects == 0 and safety)
    .then(apply(commit(m, 2, "none")))
    .expect(m.d.outbox == 3 and m.d.terminal == 1 and m.d.effects == 1 and safety)
  run currentTicketAfterRetryTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 3))).then(apply(prepare(m, 2, 0, 2)))
    .then(apply(pause(m, 1, "none"))).then(retryStep)
    .expect(m.d.version == 0 and m.b.present and safety)
    .then(apply(commit(m, 2, "none"))).then(apply(commit(m, 2, "none")))
    .expect(m.d.terminal == 2 and m.d.effects == 1 and m.d.version == 1 and safety)
  run staleTicketAfterRetryTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 3))).then(apply(prepare(m, 2, 0, 1)))
    .then(apply(pause(m, 1, "none"))).then(interferenceStep).then(retryStep)
    .then(apply(commit(m, 2, "none")))
    .expect(m.d.outbox == 1 and m.d.effects == 0 and m.b.present and safety)
    .then(apply(prepare(m, 1, 0, 1))).then(apply(commit(m, 1, "none")))
    .expect(m.d.terminal == 1 and m.d.effects == 1 and m.d.version == 2 and safety)
  run crashBeforeCommitTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 1))).then(crashStep)
    .expect(m.d.outbox == 1 and m.d.effects == 0)
    .then(restartStep).then(apply(prepare(m, 2, 0, 1))).then(apply(commit(m, 2, "none")))
    .expect(m.d.effects == 1 and safety)
  run crashAfterCommitTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 2))).then(apply(commit(m, 1, "none"))).then(crashStep)
    .expect(m.d.outbox == 3 and m.d.effects == 1 and m.reply == 0)
    .then(restartStep).then(apply(readReceipt(m, 1, true, "none")))
    .expect(m.reply == 2 and m.d.effects == 1 and safety)
  run foreignReadsAndRetriesTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 1))).then(apply(commit(m, 1, "none")))
    .then(apply(readReceipt(m, 2, false, "none")))
    .then(apply(readReceipt(m, 2, true, "none")))
    .expect(m.reply == 0 and safety)
  run revokedReceiptReadTest = init.then(admitStep)
    .then(apply(prepare(m, 1, 0, 1))).then(apply(commit(m, 1, "none")))
    .then(requesterRevokeStep).then(apply(readReceipt(m, 1, true, "none")))
    .expect(m.reply == 0 and safety)
}
