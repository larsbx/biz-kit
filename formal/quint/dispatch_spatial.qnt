// GEV-01: one page, two scopes, one participant, two observations, three stream
// IDs and cursor values 0..2. Scope represents the full selected identity tuple,
// not the authority of a client-supplied hash. Generation and work epochs model
// cancellation fences; aborted network callbacks may still arrive.
//
// This is a finite protocol model. It does not prove HTTP, Elixir/Ash, consent
// SQL, browser timers, digest collision resistance or physical sensor truth.
module dispatch_spatial_spec {
  const CHECK_SCOPE: bool
  const CHECK_CURSOR: bool
  const CHECK_WORK: bool

  type State = {
    phase: str, expected: int, generation: int, stream: int, cursor: int,
    highCursor: int, visible: int, visibleScope: int, selected: int,
    work: int, workScope: int, workEpoch: int, shownWorkEpoch: int,
    allowedWork: bool, pending: bool, requestEpoch: int,
    requestGeneration: int, requestObservation: int, requestScope: int,
    heartbeat: int, watches: bool, business: int,
    accepted: bool, deleted: bool, ignored: bool, refusedWork: bool,
  }
  type Frame = {
    scope: int, generation: int, kind: str, stream: int,
    cursor: int, visible: int, valid: bool,
  }
  var s: State

  pure def erase(v: State): State = v
    .with("phase", "stopped").with("generation", v.generation + 1)
    .with("visible", 0).with("selected", 0).with("work", 0)
    .with("workEpoch", v.workEpoch + 1).with("allowedWork", false)
    .with("watches", false)

  pure def decision(v: State, f: Frame): str =
    if (v.phase == "stopped" or f.generation != v.generation) "ignore"
    else if ((CHECK_SCOPE and f.scope != v.expected) or not(f.valid)) "clear"
    else if (v.phase == "snapshot") {
      if (f.kind == "get" and f.cursor == 0) "apply" else "clear"
    } else if (v.phase == "handoff") {
      if (f.kind == "stream" and f.cursor == 0 and f.stream != v.stream) "apply" else "clear"
    } else if (f.kind != "stream" or f.stream != v.stream) "clear"
    else if (CHECK_CURSOR and f.cursor <= v.cursor) "ignore"
    else "apply"

  pure def replace(v: State, f: Frame): State = v
    .with("phase", if (f.kind == "get") "handoff" else "streaming")
    .with("stream", f.stream).with("cursor", f.cursor)
    .with("highCursor", if (v.phase == "streaming" and v.highCursor > f.cursor) v.highCursor else f.cursor)
    .with("visible", f.visible).with("visibleScope", f.scope)
    .with("selected", if (v.selected == f.visible) v.selected else 0)
    .with("work", 0).with("workEpoch", v.workEpoch + 1)
    .with("allowedWork", true).with("heartbeat", v.heartbeat + 1)
    .with("watches", f.kind == "stream").with("accepted", true)
    .with("deleted", v.deleted or f.visible == 0)

  action receive(f: Frame): bool = {
    val d = decision(s, f)
    s' = if (d == "ignore") s.with("ignored", true)
      else if (d == "clear") erase(s)
      else replace(s, f)
  }

  action init = s' = {
    phase: "snapshot", expected: 0, generation: 1, stream: 0, cursor: 0,
    highCursor: 0, visible: 0, visibleScope: 0, selected: 0,
    work: 0, workScope: 0, workEpoch: 0, shownWorkEpoch: 0,
    allowedWork: false, pending: false, requestEpoch: 0,
    requestGeneration: 0, requestObservation: 0, requestScope: 0,
    heartbeat: 0, watches: false, business: 7,
    accepted: false, deleted: false, ignored: false, refusedWork: false,
  }

  action initialGet = all {
    s.phase == "snapshot",
    receive({scope: s.expected, generation: s.generation, kind: "get",
      stream: 1, cursor: 0, visible: 1, valid: true}),
  }

  action firstSse = all {
    s.phase == "handoff",
    receive({scope: s.expected, generation: s.generation, kind: "stream",
      stream: 2, cursor: 0, visible: 1, valid: true}),
  }

  action advance(observation: int): bool = all {
    s.phase == "streaming", s.cursor < 2,
    receive({scope: s.expected, generation: s.generation, kind: "stream",
      stream: s.stream, cursor: s.cursor + 1, visible: observation, valid: true}),
  }

  action staleFrame = all {
    s.phase == "streaming",
    receive({scope: s.expected, generation: s.generation, kind: "stream",
      stream: s.stream, cursor: 0, visible: 1, valid: true}),
  }

  action foreignScope = all {
    s.phase != "stopped",
    receive({scope: 1 - s.expected, generation: s.generation,
      kind: if (s.phase == "snapshot") "get" else "stream",
      stream: if (s.phase == "snapshot") 1 else 2,
      cursor: if (s.phase == "streaming") 2 else 0, visible: 1, valid: true}),
  }

  action foreignStream = all {
    s.phase == "streaming",
    receive({scope: s.expected, generation: s.generation, kind: "stream",
      stream: 3, cursor: 2, visible: 1, valid: true}),
  }

  action oldGeneration = receive({
    scope: s.expected, generation: s.generation - 1, kind: "stream",
    stream: 2, cursor: 2, visible: 1, valid: true,
  })

  action malformed = all {
    s.phase != "stopped",
    receive({scope: s.expected, generation: s.generation, kind: "stream",
      stream: 2, cursor: 2, visible: 1, valid: false}),
  }

  action requestWork = all {
    s.phase != "stopped", s.visible != 0, s.allowedWork, not(s.pending),
    s.workEpoch < 16,
    s' = s.with("selected", s.visible).with("work", 0)
      .with("workEpoch", s.workEpoch + 1).with("pending", true)
      .with("requestEpoch", s.workEpoch + 1)
      .with("requestGeneration", s.generation)
      .with("requestObservation", s.visible).with("requestScope", s.expected),
  }

  action deliverWork = {
    val current = s.phase != "stopped" and s.allowedWork
      and s.requestScope == s.expected and s.requestGeneration == s.generation
      and s.requestEpoch == s.workEpoch and s.requestObservation == s.selected
      and s.requestObservation == s.visible
    val accepted = current or not(CHECK_WORK)
    all {
      s.pending,
      s' = s.with("pending", false)
        .with("work", if (accepted) s.requestObservation else s.work)
        .with("workScope", if (accepted) s.requestScope else s.workScope)
        .with("shownWorkEpoch", if (accepted) s.requestEpoch else s.shownWorkEpoch)
        .with("refusedWork", s.refusedWork or not(current)),
    }
  }

  // Represents permission loss discovered by an authorized refresh. No scope
  // change or location removal is required for separate work access to end.
  action revokeWork = all {
    s.allowedWork,
    s' = s.with("allowedWork", false).with("work", 0)
      .with("workEpoch", s.workEpoch + 1),
  }

  action disconnect = all { s.phase != "stopped", s' = erase(s) }

  // A new authorized document/connection may select either scope. Old queued
  // replies remain possible; their recorded generation/epoch must reject them.
  action reconnect(scope: int): bool = all {
    s.phase == "stopped", s.generation < 4,
    s' = s.with("phase", "snapshot").with("expected", scope)
      .with("stream", 0).with("cursor", 0).with("highCursor", 0),
  }

  action step = any {
    initialGet, firstSse, advance(0), advance(2), staleFrame,
    foreignScope, foreignStream, oldGeneration, malformed,
    requestWork, deliverWork, revokeWork, disconnect,
    reconnect(0), reconnect(1),
  }

  val safety =
    s.business == 7 and
    (s.phase == "stopped" implies
      (s.visible == 0 and s.selected == 0 and s.work == 0 and not(s.watches))) and
    (s.visible != 0 implies (s.visibleScope == s.expected and s.phase != "snapshot")) and
    (s.phase == "streaming" implies s.cursor == s.highCursor) and
    (s.selected != 0 implies s.selected == s.visible) and
    (s.work != 0 implies (s.phase != "stopped" and s.allowedWork and
      s.work == s.selected and s.work == s.visible and s.workScope == s.expected
      and s.shownWorkEpoch == s.workEpoch))

  val noVisibleWitness = not(s.visible != 0 and s.watches)
  val noDeletionWitness = not(s.deleted and s.visible == 0 and s.watches)
  val noIgnoredWitness = not(s.ignored)
  val noWorkWitness = not(s.work != 0)
  val noRefusedWorkWitness = not(s.refusedWork)

  run liveSelectionTest = init.then(initialGet).then(firstSse)
    .then(requestWork).then(deliverWork)
    .expect(all { safety, s.work == 1 and s.watches })
  run deletionAndReplayTest = init.then(initialGet).then(firstSse)
    .then(advance(0)).then(staleFrame)
    .expect(all { safety, s.visible == 0 and s.heartbeat == 3 and s.ignored })
  run duplicateDoesNotRenewTest = init.then(initialGet).then(firstSse)
    .then(staleFrame)
    .expect(all { safety, s.heartbeat == 2 and s.ignored })
  run scopeRefusalTest = init.then(initialGet).then(foreignScope)
    .expect(all { safety, s.phase == "stopped" and s.visible == 0 })
  run streamRefusalTest = init.then(initialGet).then(firstSse).then(foreignStream)
    .expect(all { safety, s.phase == "stopped" and not(s.watches) })
  run lateWorkAfterClearTest = init.then(initialGet).then(requestWork)
    .then(disconnect).then(deliverWork)
    .expect(all { safety, s.work == 0 and s.refusedWork })
  run lateWorkAfterObservationTest = init.then(initialGet).then(firstSse)
    .then(requestWork).then(advance(2)).then(deliverWork)
    .expect(all { safety, s.work == 0 and s.refusedWork and s.visible == 2 })
  run workRevocationTest = init.then(initialGet).then(requestWork)
    .then(revokeWork).then(deliverWork)
    .expect(all { safety, s.work == 0 and s.refusedWork })
  run newScopeRejectsOldGenerationTest = init.then(initialGet).then(firstSse)
    .then(disconnect).then(reconnect(1)).then(oldGeneration)
    .expect(all { safety, s.visible == 0 and s.phase == "snapshot" })

  // Deterministic transitions used by the deliberately weakened controls.
  // They produce invariant violations, not parse/type errors or missed samples.
  action scopeCounterexampleStep =
    if (s.phase == "snapshot") initialGet else foreignScope
  action cursorCounterexampleStep =
    if (s.phase == "snapshot") initialGet
    else if (s.phase == "handoff") firstSse
    else if (not(s.deleted)) advance(0) else staleFrame
  action workCounterexampleStep =
    if (s.phase == "snapshot") initialGet
    else if (s.pending) {
      if (s.phase == "stopped") deliverWork else disconnect
    } else requestWork
}

module dispatch_spatial {
  import dispatch_spatial_spec(CHECK_SCOPE = true, CHECK_CURSOR = true, CHECK_WORK = true).*
}
module dispatch_spatial_scope_bug {
  import dispatch_spatial_spec(CHECK_SCOPE = false, CHECK_CURSOR = true, CHECK_WORK = true).*
}
module dispatch_spatial_cursor_bug {
  import dispatch_spatial_spec(CHECK_SCOPE = true, CHECK_CURSOR = false, CHECK_WORK = true).*
}
module dispatch_spatial_work_bug {
  import dispatch_spatial_spec(CHECK_SCOPE = true, CHECK_CURSOR = true, CHECK_WORK = false).*
}

// Independently model the server-side exact-source consent boundary. The
// booleans denote independently resolved server facts, never caller assertions.
module dispatch_spatial_source_spec {
  const BIND_ORIGINAL: bool
  type Read = {
    sameTenant: bool, sameOrganization: bool, selectedAuthority: bool,
    sessionCurrent: bool, roleCurrent: bool, participantRead: bool,
    preciseRead: bool, originalConsent: int, currentConsent: int,
    activeConsent: bool, coversAcquisition: bool,
  }
  var disclosed: bool
  var validDisclosure: bool
  var refused: bool

  pure def authority(r: Read): bool = r.sameTenant and r.sameOrganization
    and r.selectedAuthority and r.sessionCurrent and r.roleCurrent
    and r.participantRead and r.preciseRead
  pure def consent(r: Read): bool = r.activeConsent and r.coversAcquisition
    and r.originalConsent == r.currentConsent

  action init = all { disclosed' = false, validDisclosure' = true, refused' = false }
  action read(r: Read): bool = {
    val eligible = authority(r) and consent(r)
    val accepted = authority(r) and r.activeConsent and r.coversAcquisition
      and (not(BIND_ORIGINAL) or r.originalConsent == r.currentConsent)
    all {
      disclosed' = accepted,
      validDisclosure' = (not(accepted) or eligible),
      refused' = not(accepted),
    }
  }
  pure val permitted = {
    sameTenant: true, sameOrganization: true, selectedAuthority: true,
    sessionCurrent: true, roleCurrent: true, participantRead: true,
    preciseRead: true, originalConsent: 1, currentConsent: 1,
    activeConsent: true, coversAcquisition: true,
  }
  action step = {
    nondet weakened = Set("tenant", "organization", "authority", "session", "role",
      "participant", "precise", "consent", "active", "acquisition", "allowed").oneOf()
    read(if (weakened == "tenant") permitted.with("sameTenant", false)
      else if (weakened == "organization") permitted.with("sameOrganization", false)
      else if (weakened == "authority") permitted.with("selectedAuthority", false)
      else if (weakened == "session") permitted.with("sessionCurrent", false)
      else if (weakened == "role") permitted.with("roleCurrent", false)
      else if (weakened == "participant") permitted.with("participantRead", false)
      else if (weakened == "precise") permitted.with("preciseRead", false)
      else if (weakened == "consent") permitted.with("currentConsent", 2)
      else if (weakened == "active") permitted.with("activeConsent", false)
      else if (weakened == "acquisition") permitted.with("coversAcquisition", false)
      else permitted)
  }
  val safety = validDisclosure
  val noAcceptedWitness = not(disclosed)
  val noRefusalWitness = not(refused)
  run acceptedSourceTest = init.then(read(permitted)).expect(disclosed and safety)
  run renewedConsentDoesNotReviveTest = init.then(read(permitted.with("currentConsent", 2)))
    .expect(not(disclosed) and refused and safety)
  action consentCounterexampleStep = read(permitted.with("currentConsent", 2))
}
module dispatch_spatial_source {
  import dispatch_spatial_source_spec(BIND_ORIGINAL = true).*
}
module dispatch_spatial_consent_bug {
  import dispatch_spatial_source_spec(BIND_ORIGINAL = false).*
}
