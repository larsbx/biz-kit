// Task timing and agent suggestions: the admission rules of
// docs/architecture/2026-10-18-task-timing-and-suggestions.md as a state
// machine. Every action is one admitted ledger event; its preconditions are
// the append gate's checks. The invariants are the design's claims, and each
// one maps to an Elixir property test.
//
//   quint run    spec/task_suggestions.qnt --invariant=safety
//   quint verify spec/task_suggestions.qnt --invariant=safety
module task_suggestions {
  // -- domain ---------------------------------------------------------------
  pure val TASKS = Set("t1", "t2")
  pure val PRINCIPALS = Set("alice", "bot")
  // Abstract timing values; 0 stands for "unscheduled".
  pure val TIMINGS = 0.to(2)
  // Bounds event IDs (receipts, suggestions) so the state space is finite.
  pure val MAX_ID = 6
  pure val NONE = -1

  type Status = Pending | Accepted | Amended | Declined | Withdrawn | Superseded
  type Kind = KCreate | KTiming

  type Task = { exists: bool, version: int, timingVersion: int, timing: int, state: str }

  type Suggestion = {
    task: str, kind: Kind, principal: str, base: int, change: int,
    rationale: int, status: Status, applied: int, reason: int
  }

  // An admitted operator task command, without provenance (suggestion IDs).
  type Cmd = { kind: str, task: str, timing: int, role: str, granted: bool }

  type State = {
    tasks: str -> Task,
    sugs: int -> Suggestion,
    opGrants: Set[str],
    sugGrants: Set[str],
    custody: int -> str,       // operator custody receipts: id -> principal
    sugArtifacts: int -> str,  // suggester receipts, a separate map
    evidence: Set[int],        // receipts cited by operator task evidence
    resolutions: int -> int,   // resolving events per suggestion
    taskLog: List[Cmd],
    nextId: int
  }

  pure def getOrElse(m: int -> int, k: int, d: int): int =
    if (m.keys().contains(k)) m.get(k) else d

  pure val NO_TASK = { exists: false, version: 0, timingVersion: 0, timing: 0, state: "none" }

  // -- task fold: depends on operator commands only -------------------------
  pure def applyCmd(ts: str -> Task, c: Cmd): str -> Task =
    if (c.kind == "create")
      ts.set(c.task, { exists: true, version: 1, timingVersion: 1, timing: c.timing, state: "inbox" })
    else if (c.kind == "revise")
      ts.setBy(c.task, t => { ...t, timingVersion: t.timingVersion + 1, timing: c.timing })
    else
      ts.setBy(c.task, t => { ...t, version: t.version + 1, state: "proposed" })

  pure def foldTasks(log: List[Cmd]): str -> Task =
    log.foldl(TASKS.mapBy(_ => NO_TASK), (ts, c) => applyCmd(ts, c))

  // -- state ----------------------------------------------------------------
  var s: State
  var prev: State
  var lastRole: str
  var lastKind: str

  action init = {
    val s0 = {
      tasks: TASKS.mapBy(_ => NO_TASK), sugs: Map(), opGrants: Set(), sugGrants: Set(),
      custody: Map(), sugArtifacts: Map(), evidence: Set(), resolutions: Map(),
      taskLog: List(), nextId: 0
    }
    all { s' = s0, prev' = s0, lastRole' = "init", lastKind' = "init" }
  }

  action emit(role: str, kind: str, s2: State): bool = all {
    s' = s2, prev' = s, lastRole' = role, lastKind' = kind
  }

  pure def pending(st: State, id: int): bool =
    st.sugs.keys().contains(id) and st.sugs.get(id).status == Pending

  // Resolve a pending suggestion; Accepted iff the applied body is the Δ unchanged.
  pure def resolve(st: State, id: int, status: Status, applied: int, reason: int): State =
    { ...st,
      sugs: st.sugs.setBy(id, g => { ...g, status: status, applied: applied, reason: reason }),
      resolutions: st.resolutions.put(id, st.resolutions.getOrElse(id, 0) + 1) }

  pure def acceptance(g: Suggestion, applied: int): Status =
    if (g.change == applied) Accepted else Amended

  // Apply a command to the live projection and record it in the operator log.
  pure def logged(st: State, kind: str, task: str, timing: int): State =
    val c = { kind: kind, task: task, timing: timing, role: "operator", granted: true }
    { ...st, tasks: applyCmd(st.tasks, c), taskLog: st.taskLog.append(c) }

  // -- governance -----------------------------------------------------------
  action grant = {
    nondet p = PRINCIPALS.oneOf()
    nondet suggester = Set(true, false).oneOf()
    emit("governance", "grant",
      if (suggester) { ...s, sugGrants: s.sugGrants.union(Set(p)) }
      else { ...s, opGrants: s.opGrants.union(Set(p)) })
  }

  action revoke = {
    nondet p = PRINCIPALS.oneOf()
    nondet suggester = Set(true, false).oneOf()
    emit("governance", "revoke",
      if (suggester) { ...s, sugGrants: s.sugGrants.exclude(Set(p)) }
      else { ...s, opGrants: s.opGrants.exclude(Set(p)) })
  }

  // -- operator -------------------------------------------------------------
  // Creating a task supersedes every other pending create suggestion for it.
  // The creating event is their resolving event: a superseded suggestion is
  // resolved exactly once, like any other.
  pure def supersedeCreates(st: State, task: str, except: int): State =
    val superseded = st.sugs.keys().filter(i =>
      val g = st.sugs.get(i)
      i != except and g.status == Pending and g.kind == KCreate and g.task == task)
    superseded.fold(st, (acc, i) => acc.resolve(i, Superseded, NONE, NONE))

  action opCreate = {
    nondet p = PRINCIPALS.oneOf()
    nondet task = TASKS.oneOf()
    nondet timing = TIMINGS.oneOf()
    nondet cite = s.sugs.keys().union(Set(NONE)).oneOf()
    val created = s.logged("create", task, timing)
    all {
      s.opGrants.contains(p),
      not(s.tasks.get(task).exists),
      cite == NONE or (pending(s, cite) and s.sugs.get(cite).kind == KCreate and s.sugs.get(cite).task == task),
      emit("operator", "create",
        val resolved = if (cite == NONE) created
                       else created.resolve(cite, acceptance(s.sugs.get(cite), timing), timing, NONE)
        resolved.supersedeCreates(task, cite))
    }
  }

  action opRevise = {
    nondet p = PRINCIPALS.oneOf()
    nondet task = TASKS.oneOf()
    nondet expected = 0.to(MAX_ID).oneOf()
    nondet timing = TIMINGS.oneOf()
    nondet cite = s.sugs.keys().union(Set(NONE)).oneOf()
    val revised = s.logged("revise", task, timing)
    all {
      s.opGrants.contains(p),
      s.tasks.get(task).exists,
      expected == s.tasks.get(task).timingVersion,
      cite == NONE or (pending(s, cite) and s.sugs.get(cite).kind == KTiming and s.sugs.get(cite).task == task),
      emit("operator", "revise",
        if (cite == NONE) revised
        else revised.resolve(cite, acceptance(s.sugs.get(cite), timing), timing, NONE))
    }
  }

  // The existing lifecycle command (inbox -> proposed): the other facet.
  action opPropose = {
    nondet p = PRINCIPALS.oneOf()
    nondet task = TASKS.oneOf()
    all {
      s.opGrants.contains(p),
      s.tasks.get(task).state == "inbox",
      emit("operator", "propose", s.logged("propose", task, s.tasks.get(task).timing))
    }
  }

  action opDecline = {
    nondet p = PRINCIPALS.oneOf()
    nondet id = s.sugs.keys().union(Set(NONE)).oneOf()
    nondet reason = s.custody.keys().union(Set(NONE)).oneOf()
    all {
      s.opGrants.contains(p),
      pending(s, id),
      emit("operator", "decline", s.resolve(id, Declined, NONE, reason))
    }
  }

  action opCustody = {
    nondet p = PRINCIPALS.oneOf()
    all {
      s.opGrants.contains(p),
      s.nextId < MAX_ID,
      emit("operator", "custody", { ...s, custody: s.custody.put(s.nextId, p), nextId: s.nextId + 1 })
    }
  }

  // DoD evidence, SOP acknowledgement and ready inputs: resolved from custody only.
  action opEvidence = {
    nondet p = PRINCIPALS.oneOf()
    nondet r = s.custody.keys().union(Set(NONE)).oneOf()
    all {
      s.opGrants.contains(p),
      s.custody.keys().contains(r),
      emit("operator", "evidence", { ...s, evidence: s.evidence.union(Set(r)) })
    }
  }

  // -- suggester ------------------------------------------------------------
  pure def ownArtifactOrNone(st: State, r: int, p: str): bool =
    r == NONE or (st.sugArtifacts.keys().contains(r) and st.sugArtifacts.get(r) == p)

  action sugArtifact = {
    nondet p = PRINCIPALS.oneOf()
    all {
      s.sugGrants.contains(p),
      s.nextId < MAX_ID,
      emit("suggester", "artifact", { ...s, sugArtifacts: s.sugArtifacts.put(s.nextId, p), nextId: s.nextId + 1 })
    }
  }

  action sugSuggest = {
    nondet p = PRINCIPALS.oneOf()
    nondet task = TASKS.oneOf()
    nondet kind = Set(KCreate, KTiming).oneOf()
    nondet change = TIMINGS.oneOf()
    nondet base = 0.to(MAX_ID).oneOf()
    nondet rationale = s.sugArtifacts.keys().union(Set(NONE)).oneOf()
    val t = s.tasks.get(task)
    all {
      s.sugGrants.contains(p),
      s.nextId < MAX_ID,
      if (kind == KCreate) not(t.exists) else (t.exists and base <= t.timingVersion),
      ownArtifactOrNone(s, rationale, p),
      emit("suggester", "suggest", { ...s,
        sugs: s.sugs.put(s.nextId, {
          task: task, kind: kind, principal: p, base: base, change: change,
          rationale: rationale, status: Pending, applied: NONE, reason: NONE }),
        nextId: s.nextId + 1 })
    }
  }

  action sugWithdraw = {
    nondet p = PRINCIPALS.oneOf()
    nondet id = s.sugs.keys().union(Set(NONE)).oneOf()
    nondet reason = s.sugArtifacts.keys().union(Set(NONE)).oneOf()
    all {
      s.sugGrants.contains(p),
      pending(s, id),
      s.sugs.get(id).principal == p,
      ownArtifactOrNone(s, reason, p),
      emit("suggester", "withdraw", s.resolve(id, Withdrawn, NONE, reason))
    }
  }

  action step = any {
    grant, revoke,
    opCreate, opRevise, opPropose, opDecline, opCustody, opEvidence,
    sugArtifact, sugSuggest, sugWithdraw,
  }

  // -- invariants (properties 1-9 of the design) ----------------------------
  pure def allSugs(st: State, f: Suggestion => bool): bool = st.sugs.keys().forall(i => f(st.sugs.get(i)))

  // 1. No agent effect: the live projection equals a replay of operator
  //    commands alone, and
  //    no suggester event changes it or anything an operator command reads.
  val tasksFoldOperatorLog = s.tasks == foldTasks(s.taskLog)
  val suggesterLeavesTasks =
    lastRole == "suggester" implies all {
      s.tasks == prev.tasks, s.taskLog == prev.taskLog,
      s.custody == prev.custody, s.evidence == prev.evidence,
    }

  // 2. Facet independence.
  val facetIndependence = TASKS.forall(t => all {
    lastKind == "revise" implies s.tasks.get(t).version == prev.tasks.get(t).version,
    lastKind == "propose" implies s.tasks.get(t).timingVersion == prev.tasks.get(t).timingVersion,
  })

  // 3. Role separation: every task-affecting command was signed by a granted operator.
  val operatorOnly = s.taskLog.foldl(true, (ok, c) => ok and c.role == "operator" and c.granted)

  // 4. Single resolution, and a closed suggestion stays closed.
  val singleResolution = s.sugs.keys().forall(i =>
    s.resolutions.getOrElse(i, 0) == (if (s.sugs.get(i).status == Pending) 0 else 1))
  val statusMonotone = prev.sugs.keys().forall(i =>
    s.sugs.keys().contains(i) and
    (prev.sugs.get(i).status != Pending implies s.sugs.get(i).status == prev.sugs.get(i).status))

  // 5. Round trip: Accepted iff the applied body is the Δ, Amended iff not.
  val acceptanceExact = allSugs(s, g => all {
    g.status == Accepted implies g.applied == g.change,
    g.status == Amended implies g.applied != g.change,
  })

  // 8. Receipt isolation: evidence cites operator custody only, and the two
  //    receipt maps share one event-ID space without overlap.
  val receiptIsolation = all {
    s.evidence.subseteq(s.custody.keys()),
    s.evidence.intersect(s.sugArtifacts.keys()) == Set(),
    s.custody.keys().intersect(s.sugArtifacts.keys()) == Set(),
  }

  // An agent cites only its own documents; an operator's decline reason is
  // operator custody.
  val citationOwnership = allSugs(s, g => all {
    ownArtifactOrNone(s, g.rationale, g.principal),
    g.status == Withdrawn implies ownArtifactOrNone(s, g.reason, g.principal),
    g.status == Declined implies (g.reason == NONE or s.custody.keys().contains(g.reason)),
  })

  // 9. Reasons survive closure.
  val reasonsSurvive = allSugs(s, g =>
    (g.status == Declined or g.status == Withdrawn) implies
      (g.rationale == NONE or s.sugArtifacts.keys().contains(g.rationale)))

  // Superseded only ever applies to creates whose task now exists.
  val supersededSound = allSugs(s, g =>
    g.status == Superseded implies (g.kind == KCreate and s.tasks.get(g.task).exists))

  val safety = all {
    tasksFoldOperatorLog, suggesterLeavesTasks, facetIndependence, operatorOnly,
    singleResolution, statusMonotone, acceptanceExact, receiptIsolation,
    citationOwnership, reasonsSurvive, supersededSound,
  }

  // -- witnesses: each must be violated, proving the state is reachable -----
  val noAccepted = allSugs(s, g => g.status != Accepted)
  val noAmended = allSugs(s, g => g.status != Amended)
  val noDeclinedWithRationale = allSugs(s, g => not(g.status == Declined and g.rationale != NONE))
  val noSuperseded = allSugs(s, g => g.status != Superseded)
  val noWithdrawnWithReason = allSugs(s, g => not(g.status == Withdrawn and g.reason != NONE))
  val noStaleAccept = allSugs(s, g => not(g.status == Accepted and g.kind == KTiming and g.base < s.tasks.get(g.task).timingVersion - 1))
}
