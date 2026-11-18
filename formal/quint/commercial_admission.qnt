// Independent finite commercial admission model, authored from the contract,
// not generated from Lean or Elixir. Two pair scopes each have two original
// sources; all four have equal amounts. Key 5 is an identical-total impostor.
// Finite integers stand for distinct authenticated event IDs/hash bytes. No
// collision resistance, signature verification, corporate agency, contractual
// release, accounting recognition or financial settlement is proved here.
// A worker validates a snapshot and commits only at that snapshot's ledger
// version. This models both one serialized writer and a stale second writer.
module commercial_admission {
  type Core = {
    profile: int, profileEvent: int, profileHash: int, revision: int, closed: Set[int],
    authorityActive: bool, authorityEpoch: int, partyEpoch: int,
    reserved: Set[int], intents: Set[int], events: Set[int],
  }
  type Proposal = {
    chapter: int, version: int, profileEvent: int, profileHash: int, event: int, intent: int, pair: int,
    left: int, right: int, originLeft: int, originRight: int,
    hashLeft: int, hashRight: int, revision: int,
    latestLeft: int, latestRight: int, leftAmount: int, rightAmount: int,
    authorityEpoch: int, authorityHash: int, partyEpoch: int,
  }
  type Entry = { kind: str, proposal: Proposal, before: Core, batchOK: bool }
  type Worker = { ready: bool, expected: int, snapshot: Core, proposal: Proposal }
  type State = {
    journal: List[Entry], core: Core, workers: int -> Worker,
    result: str,
  }
  var s: State

  pure val emptyCore: Core = {
    profile: 0, profileEvent: 0, profileHash: 0, revision: 0, closed: Set(),
    authorityActive: true, authorityEpoch: 1, partyEpoch: 1,
    reserved: Set(), intents: Set(), events: Set(),
  }
  pure def isEmpty(xs: Set[int]): bool = xs.size() == 0
  pure def left(pair: int): int = 1 + pair * 2
  pure def right(pair: int): int = 2 + pair * 2
  pure def sourceKeys(p: Proposal): Set[int] = Set(p.left, p.right)
  pure def revision(c: Core, pair: int): int = if (pair == 0) c.revision else 0
  pure def request(c: Core, intent: int, event: int, pair: int): Proposal = {
    chapter: 1, version: 2, profileEvent: c.profileEvent, profileHash: c.profileHash,
    event: event, intent: intent, pair: pair,
    left: left(pair), right: right(pair),
    originLeft: 100 + left(pair), originRight: 100 + right(pair),
    hashLeft: 10 * left(pair), hashRight: 10 * right(pair),
    revision: revision(c, pair),
    latestLeft: 10 * left(pair) + revision(c, pair), latestRight: 10 * right(pair),
    leftAmount: 100, rightAmount: 100,
    authorityEpoch: c.authorityEpoch, authorityHash: 1000 + c.authorityEpoch,
    partyEpoch: c.partyEpoch,
  }
  pure val emptyProposal: Proposal = request(emptyCore, 0, 0, 0)
  pure val emptyWorker: Worker = {
    ready: false, expected: 0, snapshot: emptyCore, proposal: emptyProposal,
  }
  pure def identityOK(p: Proposal): bool = p.chapter == 1 and Set(0, 1).contains(p.pair)
    and p.left == left(p.pair) and p.right == right(p.pair)
    and p.originLeft == 100 + left(p.pair) and p.originRight == 100 + right(p.pair)
  pure def originHashOK(p: Proposal): bool = p.hashLeft == 10 * left(p.pair)
    and p.hashRight == 10 * right(p.pair)
  pure def revisionOK(c: Core, p: Proposal): bool = p.revision == revision(c, p.pair)
    and revision(c, p.pair) == 0
  pure def latestHashOK(c: Core, p: Proposal): bool = p.latestLeft == 10 * left(p.pair) + revision(c, p.pair)
    and p.latestRight == 10 * right(p.pair)
  pure def authorityOK(c: Core, p: Proposal): bool = c.authorityActive and p.authorityEpoch == c.authorityEpoch
    and p.authorityHash == 1000 + c.authorityEpoch
  pure def memberOK(c: Core, p: Proposal): bool = p.partyEpoch == c.partyEpoch
  pure def ready(c: Core, p: Proposal, mutant: str): bool =
    (c.profile == 2 or mutant == "profile")
    and (p.version == 2 or mutant == "version")
    and ((p.profileEvent == c.profileEvent and p.profileHash == c.profileHash) or mutant == "profileBinding")
    and (identityOK(p) or mutant == "identity")
    and (originHashOK(p) or mutant == "origin")
    and (revisionOK(c, p) or mutant == "revision")
    and (latestHashOK(c, p) or mutant == "latest")
    and p.leftAmount == 100 and p.rightAmount == 100
    and sourceKeys(p).intersect(c.closed).isEmpty()
    and (authorityOK(c, p) or mutant == "authority")
    and (memberOK(c, p) or mutant == "member")
    and (sourceKeys(p).intersect(c.reserved).isEmpty() or mutant == "reservation")
    and (not(c.intents.contains(p.intent)) or mutant == "intent")
    and (not(c.events.contains(p.event)) or mutant == "event")

  pure def applyEvent(c: Core, e: Entry): Core = if (e.kind == "activate") { ...c, profile: 2, profileEvent: 50, profileHash: 500 }
    else if (e.kind == "proposal") {
      ...c, reserved: c.reserved.union(sourceKeys(e.proposal)),
      intents: c.intents.union(Set(e.proposal.intent)),
      events: c.events.union(Set(e.proposal.event)),
    }
    else if (e.kind == "netting" or e.kind == "discharge") {
      ...c, closed: c.closed.union(Set(1, 2)),
    }
    else if (e.kind == "assignment") { ...c, revision: c.revision + 1 }
    else if (e.kind == "revoke") { ...c, authorityActive: false }
    else if (e.kind == "restore") {
      ...c, authorityActive: true, authorityEpoch: c.authorityEpoch + 1,
    }
    else if (e.kind == "rotate") { ...c, partyEpoch: c.partyEpoch + 1 }
    else c

  // Recovery derives everything from durable events. It never applies a new
  // admission rule to an old envelope and never takes a caller's profile.
  pure def replay(journal: List[Entry]): Core = journal.foldl(emptyCore, (c, e) => applyEvent(c, e))
  pure def entry(kind: str, p: Proposal, c: Core, batchOK: bool): Entry = {
    kind: kind, proposal: p, before: c, batchOK: batchOK,
  }
  pure def publish(state: State, kind: str, p: Proposal, batchOK: bool): State = {
    val e = entry(kind, p, state.core, batchOK)
    { ...state, journal: state.journal.append(e), core: applyEvent(state.core, e), result: "accepted" }
  }

  action init = s' = {
    journal: [], core: emptyCore,
    workers: Set(1, 2).mapBy(_ => emptyWorker), result: "initial",
  }
  action idle = s' = s
  action activateWith(p, mutant) = s' =
    if (s.core.profile == 0 and s.core.authorityActive
      and (authorityOK(s.core, p) or mutant == "activation"))
      publish(s, "activate", p, true) else { ...s, result: "rejected" }
  action activate = activateWith(request(s.core, 0, 0, 0), "safe")
  action prepare(worker, intent, event, pair) = s' = {
    ...s, workers: s.workers.set(worker, {
      ready: true, expected: s.journal.length(), snapshot: s.core,
      proposal: request(s.core, intent, event, pair),
    }), result: "prepared",
  }
  // Re-read the authoritative head while retaining already signed bytes.
  action refresh(worker) = {
    val w = s.workers.get(worker)
    s' = { ...s, workers: s.workers.set(worker,
      { ...w, expected: s.journal.length(), snapshot: s.core }), result: "refreshed" }
  }
  pure def changed(p: Proposal, what: str): Proposal = if (what == "identity") {
      ...p, right: 5, originRight: 105,
    }
    else if (what == "chapter") { ...p, chapter: 2 }
    else if (what == "origin") { ...p, hashLeft: 99 }
    else if (what == "revision") { ...p, revision: p.revision + 1 }
    else if (what == "latest") { ...p, latestLeft: 99 }
    else if (what == "profileBinding") { ...p, profileHash: 99 }
    else if (what == "version") { ...p, version: 3 }
    else if (what == "legacyVersion") { ...p, version: 0 }
    else if (what == "authority") { ...p, authorityHash: 99 }
    else if (what == "member") { ...p, partyEpoch: p.partyEpoch + 1 }
    else if (what == "event") { ...p, event: p.event + 2 }
    else p
  action tamper(worker, what) = {
    val w = s.workers.get(worker)
    s' = { ...s, workers: s.workers.set(worker,
      { ...w, proposal: changed(w.proposal, what) }), result: "changed" }
  }
  pure def sameReceipt(journal: List[Entry], p: Proposal): bool = journal.indices().exists(i =>
    journal[i].kind == "proposal" and journal[i].proposal == p)
  action commit(worker, mutant) = {
    val w = s.workers.get(worker)
    val retry = sameReceipt(s.journal, w.proposal)
    val fresh = w.expected == s.journal.length()
    val allowed = w.ready and (fresh or mutant == "cas") and ready(w.snapshot, w.proposal, mutant)
    val accepted = publish(s, "proposal", w.proposal, true)
    s' = if (retry) { ...s, result: "historical_receipt" }
      else if (allowed) {
        ...accepted,
        core: if (mutant == "discharge") {
          ...accepted.core, closed: accepted.core.closed.union(sourceKeys(w.proposal)),
        } else accepted.core,
      }
      else if (not(fresh)) {
        ...s, workers: s.workers.set(worker, { ...w, ready: false }), result: "stale_writer_stopped",
      }
      else { ...s, result: "rejected" }
  }
  action legacy(kind, mutant) = s' =
    if (s.core.profile == 0 or mutant == "caller_profile")
      publish(s, kind, { ...emptyProposal, version: 0 }, true)
    else { ...s, result: "rejected" }
  action authority(kind) = s' =
    if ((kind == "revoke" and not(s.core.authorityActive))
      or (kind == "restore" and s.core.authorityActive)) { ...s, result: "rejected" }
    else publish(s, kind, emptyProposal, true)
  action restart(mutant) = {
    val recovered = replay(s.journal)
    s' = {
      ...s, core: if (mutant == "recovery") { ...recovered, reserved: Set() } else recovered,
      workers: Set(1, 2).mapBy(_ => emptyWorker), result: "recovered",
    }
  }
  // First candidate is valid, second candidate is invalid. Neither may commit.
  action rejectedBatch(mutant) = {
    val w = s.workers.get(1)
    s' = if (mutant == "atomic" and w.expected == s.journal.length()
      and ready(w.snapshot, w.proposal, "safe"))
      publish(s, "proposal", w.proposal, false)
    else { ...s, result: "batch_rejected" }
  }

  val journalAdmission = s.journal.indices().forall(i => {
    val e = s.journal[i]
    if (e.kind == "proposal") ready(e.before, e.proposal, "safe") and e.batchOK
    else if (Set("netting", "discharge", "assignment", "v1").contains(e.kind)) e.before.profile == 0
    else if (e.kind == "activate") e.before.profile == 0 and authorityOK(e.before, e.proposal)
    else true
  })
  val uniqueSources = s.journal.indices().forall(i => s.journal.indices().forall(j =>
    i == j or s.journal[i].kind != "proposal" or s.journal[j].kind != "proposal"
      or sourceKeys(s.journal[i].proposal).intersect(sourceKeys(s.journal[j].proposal)).isEmpty()))
  val uniqueIntents = s.journal.indices().forall(i => s.journal.indices().forall(j =>
    i == j or s.journal[i].kind != "proposal" or s.journal[j].kind != "proposal"
      or s.journal[i].proposal.intent != s.journal[j].proposal.intent))
  val recoveredExactly = s.core == replay(s.journal)
  // Compute the only permitted closure causes separately from the replay fold.
  val noProposalDischarge = s.core.closed == s.journal.foldl(Set(), (closed, e) =>
    if (e.kind == "netting" or e.kind == "discharge") closed.union(Set(1, 2)) else closed)
  val safety = journalAdmission and uniqueSources and uniqueIntents
    and recoveredExactly and noProposalDischarge

  action samplePrepare = {
    nondet worker = Set(1, 2).oneOf()
    nondet intent = Set(1, 2).oneOf()
    nondet event = Set(1, 2, 3).oneOf()
    nondet pair = Set(0, 1).oneOf()
    prepare(worker, intent, event, pair)
  }
  action sampleCommit = { nondet worker = Set(1, 2).oneOf(); commit(worker, "safe") }
  action sampleTamper = {
    nondet worker = Set(1, 2).oneOf()
    nondet what = Set("identity", "chapter", "origin", "revision", "latest", "version", "profileBinding", "authority", "member").oneOf()
    tamper(worker, what)
  }
  action sampleLegacy = {
    nondet kind = Set("netting", "discharge", "assignment", "v1").oneOf()
    legacy(kind, "safe")
  }
  action step = any {
    activate, samplePrepare, sampleCommit, sampleTamper, sampleLegacy,
    authority("revoke"), authority("restore"), authority("rotate"),
    refresh(1), refresh(2), restart("safe"), rejectedBatch("safe"), idle,
  }

  // Smaller symbolic interleaving slice retains the full invariants but fixes
  // pair 0, two independently prepared writers, revocation and restart.
  action boundedStep = any {
    activate, prepare(1, 1, 1, 0), prepare(2, 2, 2, 0),
    commit(1, "safe"), commit(2, "safe"), authority("revoke"),
    restart("safe"), legacy("netting", "safe"), idle,
  }

  // Every mutant starts from a reachable valid preparation. Each action uses
  // the SAME transition with one omitted guard; the witness check below must
  // reach a safety counterexample, not a parser error or a failing assertion.
  action unprotectedPreparedInit = init.then(prepare(1, 1, 1, 0))
  action profileMutant = any { commit(1, "profile"), idle }
  action preparedInit = init.then(activate).then(prepare(1, 1, 1, 0))
  action activationMutant = any {
    authority("revoke"), authority("restore"), activateWith(s.workers.get(1).proposal, "activation"), idle,
  }
  action profileBindingMutant = any { tamper(1, "profileBinding"), commit(1, "profileBinding"), idle }
  action identityMutant = any { tamper(1, "identity"), commit(1, "identity"), idle }
  action originMutant = any { tamper(1, "origin"), commit(1, "origin"), idle }
  action revisionMutant = any { tamper(1, "revision"), commit(1, "revision"), idle }
  action latestMutant = any { tamper(1, "latest"), commit(1, "latest"), idle }
  action versionMutant = any { tamper(1, "version"), commit(1, "version"), idle }
  action authorityMutant = any { authority("revoke"), refresh(1), commit(1, "authority"), idle }
  action memberMutant = any { authority("rotate"), refresh(1), commit(1, "member"), idle }
  action reservationMutant = any {
    commit(1, "reservation"), prepare(1, 2, 2, 0), idle,
  }
  action intentMutant = any { commit(1, "intent"), prepare(1, 1, 2, 1), idle }
  action eventMutant = any { commit(1, "event"), prepare(1, 2, 1, 1), idle }
  action casMutant = any {
    prepare(2, 2, 2, 0), commit(1, "cas"), commit(2, "cas"), idle,
  }
  action callerProfileMutant = any { legacy("netting", "caller_profile"), idle }
  action recoveryMutant = any { commit(1, "safe"), restart("recovery"), idle }
  action atomicMutant = any { rejectedBatch("atomic"), idle }
  action dischargeMutant = any { commit(1, "discharge"), idle }

  run unprotectedV2RejectedTest = unprotectedPreparedInit.then(commit(1, "safe"))
    .then(all { idle, assert(s.result == "rejected" and s.journal.length() == 0 and safety) })
  run revokedGovernanceCannotActivateTest = init.then(authority("revoke")).then(activate)
    .then(all { idle, assert(s.result == "rejected" and s.core.profile == 0 and safety) })
  run heldActivationRedeclarationTest = unprotectedPreparedInit.then(authority("revoke"))
    .then(authority("restore")).then(activateWith(s.workers.get(1).proposal, "safe"))
    .then(all { idle, assert(s.result == "rejected" and s.core.profile == 0
      and s.core.authorityEpoch == 2 and safety) })
  run activationHashBindingTest = preparedInit.then(tamper(1, "profileBinding"))
    .then(commit(1, "safe")).then(all { idle, assert(s.result == "rejected" and safety) })
  run positiveInertProposalTest = preparedInit.then(commit(1, "safe"))
    .then(all { idle, assert(s.result == "accepted" and s.core.closed.isEmpty()
      and s.core.reserved == Set(1, 2) and safety) })
  run identicalTotalsSubstitutionTest = preparedInit.then(tamper(1, "identity"))
    .then(commit(1, "safe")).then(all { idle, assert(s.result == "rejected"
      and s.core.reserved.isEmpty() and safety) })
  run originalHashSubstitutionTest = preparedInit.then(tamper(1, "origin"))
    .then(commit(1, "safe")).then(all { idle, assert(s.result == "rejected" and safety) })
  run latestHashSubstitutionTest = preparedInit.then(tamper(1, "latest"))
    .then(commit(1, "safe")).then(all { idle, assert(s.result == "rejected" and safety) })
  run revisionFieldChangedTest = preparedInit.then(tamper(1, "revision"))
    .then(commit(1, "safe")).then(all { idle, assert(s.result == "rejected" and safety) })
  run assignmentOutAndBackTest = init
    .then(legacy("assignment", "safe")).then(legacy("assignment", "safe"))
    .then(activate).then(prepare(1, 1, 1, 0)).then(commit(1, "safe"))
    .then(all { idle, assert(s.result == "rejected" and s.core.revision == 2 and safety) })
  run conflictingProposalsTest = preparedInit.then(commit(1, "safe"))
    .then(prepare(2, 2, 2, 0)).then(commit(2, "safe"))
    .then(all { idle, assert(s.result == "rejected" and s.core.intents == Set(1) and safety) })
  run sameIntentDifferentPairTest = preparedInit.then(commit(1, "safe"))
    .then(prepare(2, 1, 2, 1)).then(commit(2, "safe"))
    .then(all { idle, assert(s.result == "rejected" and s.core.reserved == Set(1, 2) and safety) })
  run sameEventChangedIntentTest = preparedInit.then(commit(1, "safe"))
    .then(prepare(2, 2, 1, 1)).then(commit(2, "safe"))
    .then(all { idle, assert(s.result == "rejected" and s.core.events == Set(1) and safety) })
  run concurrentPreparedWritersTest = preparedInit.then(prepare(2, 2, 2, 0))
    .then(commit(1, "safe")).then(commit(2, "safe"))
    .then(all { idle, assert(s.result == "stale_writer_stopped"
      and not(s.workers.get(2).ready) and s.core.intents == Set(1) and safety) })
  run revokedAuthorityAtCommitTest = preparedInit.then(authority("revoke"))
    .then(refresh(1)).then(commit(1, "safe"))
    .then(all { idle, assert(s.result == "rejected" and s.core.intents.isEmpty() and safety) })
  run redeclaredSameKeyEpochTest = preparedInit.then(authority("revoke"))
    .then(authority("restore")).then(refresh(1)).then(commit(1, "safe"))
    .then(all { idle, assert(s.result == "rejected" and s.core.authorityEpoch == 2 and safety) })
  run rotatedMemberAtCommitTest = preparedInit.then(authority("rotate"))
    .then(refresh(1)).then(commit(1, "safe"))
    .then(all { idle, assert(s.result == "rejected" and safety) })
  run restoredReservationConflictTest = preparedInit.then(commit(1, "safe"))
    .then(restart("safe")).then(prepare(2, 2, 2, 0)).then(commit(2, "safe"))
    .then(all { idle, assert(s.result == "rejected" and s.core.intents == Set(1) and safety) })
  run lostReplyReturnsReceiptAfterRevocationTest = preparedInit.then(commit(1, "safe"))
    .then(authority("revoke")).then(commit(1, "safe"))
    .then(all { idle, assert(s.result == "historical_receipt"
      and s.core.intents == Set(1) and s.journal.length() == 3 and safety) })
  run failedBatchPublishesNothingTest = preparedInit.then(rejectedBatch("safe"))
    .then(restart("safe"))
    .then(all { idle, assert(s.journal.length() == 1 and s.core.reserved.isEmpty() and safety) })
  run historicalReplayPreservedTest = init.then(legacy("netting", "safe"))
    .then(activate).then(restart("safe")).then(legacy("netting", "safe"))
    .then(all { idle, assert(s.result == "rejected" and s.core.closed == Set(1, 2)
      and s.journal.length() == 2 and safety) })
  run allLegacyRoutesFencedTest = preparedInit.then(legacy("netting", "safe"))
    .then(legacy("discharge", "safe")).then(legacy("assignment", "safe"))
    .then(legacy("v1", "safe")).then(all { idle, assert(s.journal.length() == 1
      and s.core.closed.isEmpty() and s.core.revision == 0 and safety) })
  run profileCannotDowngradeTest = preparedInit.then(tamper(1, "legacyVersion"))
    .then(commit(1, "safe")).then(activate)
    .then(all { idle, assert(s.result == "rejected" and s.core.profile == 2
      and s.journal.length() == 1 and safety) })
  run unknownVersionRejectedTest = preparedInit.then(tamper(1, "version"))
    .then(commit(1, "safe")).then(all { idle, assert(s.result == "rejected" and safety) })
  run wrongChapterRejectedTest = preparedInit.then(tamper(1, "chapter"))
    .then(commit(1, "safe")).then(all { idle, assert(s.result == "rejected" and safety) })
}
