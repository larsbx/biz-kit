// Task timing, agent suggestions and delegated changes: the admission rules of
// docs/architecture/2026-10-18-task-timing-and-suggestions.md and
// docs/architecture/2026-10-18-task-delegation.md as a state machine. Every
// action is one admitted ledger event; its preconditions are the append
// gate's checks. The invariants are the design's claims, and each one maps to
// an Elixir property test.
//
//   ./check.sh   (typecheck, sampled safety, witnesses, bounded Apalache check)
module task_suggestions {
  // -- domain ---------------------------------------------------------------
  pure val TASKS = Set("t1", "t2")
  pure val PRINCIPALS = Set("alice", "bot")
  // Timing is {slot, due}. Slot 0 is unscheduled; slot 1 lies inside every
  // delegation window (and within its block length); slot 2 lies outside.
  // Due 0 is "no due date".
  type Timing = { slot: int, due: int }
  pure val SLOTS = 0.to(2)
  pure val IN_WINDOW = Set(1)
  pure val TIMINGS = SLOTS.map(sl => 0.to(1).map(d => { slot: sl, due: d })).flatten()
  pure val NO_TIMING = { slot: -1, due: -1 }
  // Bounds event IDs (receipts, suggestions, delegations) so the state space is finite.
  pure val MAX_ID = 6
  pure val NONE = -1
  pure val NEVER = 1000

  type Status = Pending | Accepted | Amended | Declined | Withdrawn | Superseded
  type Kind = KCreate | KTiming

  type Task = { exists: bool, version: int, timingVersion: int, timing: Timing, state: str }

  type Suggestion = {
    task: str, kind: Kind, principal: str, base: int, change: Timing,
    rationale: int, status: Status, applied: Timing, reason: int
  }

  // A delegation is bound to one operator-grant instance (its epoch): a later
  // re-grant of the same principal does not revive it.
  type Delegation = {
    delegator: str, epoch: int, delegate: str, kinds: Set[str], tasks: Set[str],
    states: Set[str], budget: int, used: int, active: bool,
    revokedSeq: int,      // log length when revoked; NEVER while active
    grantEndedSeq: int    // log length when the delegator's grant ended; NEVER while live
  }

  // An admitted task command. `via` is NONE for an operator, else the
  // delegation. `prev` is the timing it replaced; `seq` its log position.
  type Cmd = {
    kind: str, task: str, timing: Timing, prev: Timing,
    role: str, granted: bool, via: int, seq: int
  }

  type State = {
    tasks: str -> Task,
    sugs: int -> Suggestion,
    opGrants: str -> int,      // active operator grants: principal -> epoch
    epochs: int,               // grant instances issued so far
    sugGrants: Set[str],
    delegations: int -> Delegation,
    custody: int -> str,       // operator custody receipts: id -> principal
    sugArtifacts: int -> str,  // agent receipts, a separate map
    evidence: Set[int],        // receipts cited by operator task evidence
    resolutions: int -> int,   // resolving events per suggestion
    taskLog: List[Cmd],
    nextId: int
  }

  pure def getOrElse(m: int -> int, k: int, d: int): int =
    if (m.keys().contains(k)) m.get(k) else d

  pure val NO_TASK = { exists: false, version: 0, timingVersion: 0, timing: { slot: 0, due: 0 }, state: "none" }

  // -- task fold: depends on admitted task commands only --------------------
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
      tasks: TASKS.mapBy(_ => NO_TASK), sugs: Map(), opGrants: Map(), epochs: 0,
      sugGrants: Set(), delegations: Map(), custody: Map(), sugArtifacts: Map(),
      evidence: Set(), resolutions: Map(), taskLog: List(), nextId: 0
    }
    all { s' = s0, prev' = s0, lastRole' = "init", lastKind' = "init" }
  }

  action emit(role: str, kind: str, s2: State): bool = all {
    s' = s2, prev' = s, lastRole' = role, lastKind' = kind
  }

  pure def pending(st: State, id: int): bool =
    st.sugs.keys().contains(id) and st.sugs.get(id).status == Pending

  pure def operator(st: State, p: str): bool = st.opGrants.keys().contains(p)

  // Resolve a pending suggestion; Accepted iff the applied body is the Δ unchanged.
  pure def resolve(st: State, id: int, status: Status, applied: Timing, reason: int): State =
    { ...st,
      sugs: st.sugs.setBy(id, g => { ...g, status: status, applied: applied, reason: reason }),
      resolutions: st.resolutions.put(id, st.resolutions.getOrElse(id, 0) + 1) }

  pure def acceptance(g: Suggestion, applied: Timing): Status =
    if (g.change == applied) Accepted else Amended

  // Apply a command to the live projection and record it in the task log.
  pure def logged(st: State, kind: str, task: str, timing: Timing, role: str, via: int): State =
    val c = {
      kind: kind, task: task, timing: timing, prev: st.tasks.get(task).timing,
      role: role, granted: true, via: via, seq: st.taskLog.length()
    }
    { ...st, tasks: applyCmd(st.tasks, c), taskLog: st.taskLog.append(c) }

  // Creating a task supersedes every other pending create suggestion for it.
  // The creating event is their resolving event.
  pure def supersedeCreates(st: State, task: str, except: int): State =
    val superseded = st.sugs.keys().filter(i =>
      val g = st.sugs.get(i)
      i != except and g.status == Pending and g.kind == KCreate and g.task == task)
    superseded.fold(st, (acc, i) => acc.resolve(i, Superseded, NO_TIMING, NONE))

  // -- governance -----------------------------------------------------------
  action grant = {
    nondet p = PRINCIPALS.oneOf()
    nondet suggester = Set(true, false).oneOf()
    all {
      suggester or not(operator(s, p)),
      emit("governance", "grant",
        if (suggester) { ...s, sugGrants: s.sugGrants.union(Set(p)) }
        else { ...s, opGrants: s.opGrants.put(p, s.epochs), epochs: s.epochs + 1 })
    }
  }

  // Revoking an operator grant ends every delegation issued under it.
  action revoke = {
    nondet p = PRINCIPALS.oneOf()
    nondet suggester = Set(true, false).oneOf()
    all {
      suggester or operator(s, p),
      emit("governance", "revoke",
        if (suggester) { ...s, sugGrants: s.sugGrants.exclude(Set(p)) }
        else
          val epoch = s.opGrants.get(p)
          { ...s,
            opGrants: s.opGrants.keys().exclude(Set(p)).mapBy(q => s.opGrants.get(q)),
            delegations: s.delegations.keys().mapBy(i =>
              val d = s.delegations.get(i)
              if (d.delegator == p and d.epoch == epoch and d.grantEndedSeq == NEVER)
                { ...d, grantEndedSeq: s.taskLog.length() }
              else d) })
    }
  }

  // -- operator -------------------------------------------------------------
  action opCreate = {
    nondet p = PRINCIPALS.oneOf()
    nondet task = TASKS.oneOf()
    nondet timing = TIMINGS.oneOf()
    nondet cite = s.sugs.keys().union(Set(NONE)).oneOf()
    val created = s.logged("create", task, timing, "operator", NONE)
    all {
      operator(s, p),
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
    nondet timing = TIMINGS.oneOf()
    nondet cite = s.sugs.keys().union(Set(NONE)).oneOf()
    val revised = s.logged("revise", task, timing, "operator", NONE)
    all {
      operator(s, p),
      s.tasks.get(task).exists,
      cite == NONE or (pending(s, cite) and s.sugs.get(cite).kind == KTiming and s.sugs.get(cite).task == task),
      emit("operator", "revise",
        if (cite == NONE) revised
        else revised.resolve(cite, acceptance(s.sugs.get(cite), timing), timing, NONE))
    }
  }

  // The existing lifecycle command (inbox -> proposed): operator grants only.
  action opPropose = {
    nondet p = PRINCIPALS.oneOf()
    nondet task = TASKS.oneOf()
    all {
      operator(s, p),
      s.tasks.get(task).state == "inbox",
      emit("operator", "propose", s.logged("propose", task, s.tasks.get(task).timing, "operator", NONE))
    }
  }

  action opDecline = {
    nondet p = PRINCIPALS.oneOf()
    nondet id = s.sugs.keys().union(Set(NONE)).oneOf()
    nondet reason = s.custody.keys().union(Set(NONE)).oneOf()
    all {
      operator(s, p),
      pending(s, id),
      emit("operator", "decline", s.resolve(id, Declined, NO_TIMING, reason))
    }
  }

  action opCustody = {
    nondet p = PRINCIPALS.oneOf()
    all {
      operator(s, p),
      s.nextId < MAX_ID,
      emit("operator", "custody", { ...s, custody: s.custody.put(s.nextId, p), nextId: s.nextId + 1 })
    }
  }

  // DoD evidence, SOP acknowledgement and ready inputs: resolved from custody only.
  action opEvidence = {
    nondet p = PRINCIPALS.oneOf()
    nondet r = s.custody.keys().union(Set(NONE)).oneOf()
    all {
      operator(s, p),
      s.custody.keys().contains(r),
      emit("operator", "evidence", { ...s, evidence: s.evidence.union(Set(r)) })
    }
  }

  // An operator delegates a class of changes from their own, current grant.
  action opDelegate = {
    nondet p = PRINCIPALS.oneOf()
    nondet agent = PRINCIPALS.oneOf()
    nondet kinds = Set(Set("timing"), Set("create"), Set("timing", "create")).oneOf()
    nondet tasks = Set(TASKS, Set("t1")).oneOf()
    nondet states = Set(Set("inbox", "proposed"), Set("inbox")).oneOf()
    nondet budget = 1.to(2).oneOf()
    all {
      operator(s, p),
      s.nextId < MAX_ID,
      emit("operator", "delegate", { ...s,
        delegations: s.delegations.put(s.nextId, {
          delegator: p, epoch: s.opGrants.get(p), delegate: agent, kinds: kinds,
          tasks: tasks, states: states, budget: budget, used: 0, active: true,
          revokedSeq: NEVER, grantEndedSeq: NEVER }),
        nextId: s.nextId + 1 })
    }
  }

  action opRevokeDelegation = {
    nondet p = PRINCIPALS.oneOf()
    nondet id = s.delegations.keys().union(Set(NONE)).oneOf()
    all {
      operator(s, p),
      s.delegations.keys().contains(id),
      s.delegations.get(id).delegator == p,
      s.delegations.get(id).active,
      emit("operator", "revokeDelegation", { ...s,
        delegations: s.delegations.setBy(id, d => { ...d, active: false, revokedSeq: s.taskLog.length() }) })
    }
  }

  // -- delegated agent ------------------------------------------------------
  // Live: not revoked, its delegator's grant instance still active, budget left.
  pure def live(st: State, d: Delegation): bool = all {
    d.active,
    operator(st, d.delegator),
    st.opGrants.get(d.delegator) == d.epoch,
    d.used < d.budget,
  }

  pure def openSlot(t: Timing): bool = t.slot == 0 or IN_WINDOW.contains(t.slot)

  pure def charged(st: State, id: int): State =
    { ...st, delegations: st.delegations.setBy(id, d => { ...d, used: d.used + 1 }) }

  action delCreate = {
    nondet id = s.delegations.keys().union(Set(NONE)).oneOf()
    nondet task = TASKS.oneOf()
    nondet timing = TIMINGS.oneOf()
    all {
      s.delegations.keys().contains(id),
      val d = s.delegations.get(id)
      all {
        live(s, d),
        d.kinds.contains("create"),
        d.tasks.contains(task),
        not(s.tasks.get(task).exists),
        timing.due == 0,
        openSlot(timing),
        emit("delegate", "delCreate",
          s.logged("create", task, timing, "delegate", id).charged(id).supersedeCreates(task, NONE)),
      }
    }
  }

  action delRevise = {
    nondet id = s.delegations.keys().union(Set(NONE)).oneOf()
    nondet task = TASKS.oneOf()
    nondet timing = TIMINGS.oneOf()
    all {
      s.delegations.keys().contains(id),
      val d = s.delegations.get(id)
      val t = s.tasks.get(task)
      all {
        live(s, d),
        d.kinds.contains("timing"),
        d.tasks.contains(task),
        t.exists,
        d.states.contains(t.state),
        timing.due == t.timing.due,
        IN_WINDOW.contains(timing.slot),
        openSlot(t.timing),
        emit("delegate", "delRevise", s.logged("revise", task, timing, "delegate", id).charged(id)),
      }
    }
  }

  // -- suggester ------------------------------------------------------------
  pure def ownArtifactOrNone(st: State, r: int, p: str): bool =
    r == NONE or (st.sugArtifacts.keys().contains(r) and st.sugArtifacts.get(r) == p)

  // Agents record reasoning under a suggester grant or a live delegation.
  action sugArtifact = {
    nondet p = PRINCIPALS.oneOf()
    all {
      s.sugGrants.contains(p) or s.delegations.keys().exists(i =>
        s.delegations.get(i).delegate == p and live(s, s.delegations.get(i))),
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
          rationale: rationale, status: Pending, applied: NO_TIMING, reason: NONE }),
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
      emit("suggester", "withdraw", s.resolve(id, Withdrawn, NO_TIMING, reason))
    }
  }

  action step = any {
    grant, revoke,
    opCreate, opRevise, opPropose, opDecline, opCustody, opEvidence,
    opDelegate, opRevokeDelegation, delCreate, delRevise,
    sugArtifact, sugSuggest, sugWithdraw,
  }

  // -- invariants -----------------------------------------------------------
  pure def allSugs(st: State, f: Suggestion => bool): bool = st.sugs.keys().forall(i => f(st.sugs.get(i)))
  pure def allCmds(st: State, f: Cmd => bool): bool = st.taskLog.foldl(true, (ok, c) => ok and f(c))
  pure def usesOf(st: State, id: int): int = st.taskLog.foldl(0, (n, c) => if (c.via == id) n + 1 else n)

  // The live projection equals a replay of admitted task commands, and no
  // suggester event changes it or anything an operator command reads.
  val tasksFoldLog = s.tasks == foldTasks(s.taskLog)
  val suggesterLeavesTasks =
    lastRole == "suggester" implies all {
      s.tasks == prev.tasks, s.taskLog == prev.taskLog,
      s.custody == prev.custody, s.evidence == prev.evidence,
    }

  // Facet independence.
  val facetIndependence = TASKS.forall(t => all {
    (lastKind == "revise" or lastKind == "delRevise") implies s.tasks.get(t).version == prev.tasks.get(t).version,
    lastKind == "propose" implies s.tasks.get(t).timingVersion == prev.tasks.get(t).timingVersion,
  })

  // Delegation 1, traceability: every task command came from a granted
  // operator or through a delegation; nothing else touches the task log.
  val traceability = allCmds(s, c => c.granted and all {
    c.via == NONE implies c.role == "operator",
    c.via != NONE implies (c.role == "delegate" and s.delegations.keys().contains(c.via)),
  })

  // Delegation 2, limits, recomputed from each logged command and its delegation.
  val delegatedWithinLimits = allCmds(s, c => c.via != NONE implies
    val d = s.delegations.get(c.via)
    all {
      d.tasks.contains(c.task),
      if (c.kind == "create") all { d.kinds.contains("create"), c.timing.due == 0, openSlot(c.timing) }
      else all {
        c.kind == "revise", d.kinds.contains("timing"),
        c.timing.due == c.prev.due, IN_WINDOW.contains(c.timing.slot), openSlot(c.prev),
      },
    })

  // Delegation 3, budget: counted from the log, independently of `used`.
  val budgetRespected = s.delegations.keys().forall(i =>
    val d = s.delegations.get(i)
    usesOf(s, i) == d.used and d.used <= d.budget)

  // Delegation 4, revocation is effective: no delegated command after the
  // delegation was revoked or its delegator's grant ended.
  val revocationEffective = allCmds(s, c => c.via != NONE implies
    val d = s.delegations.get(c.via)
    c.seq < d.revokedSeq and c.seq < d.grantEndedSeq)

  // Delegation 5, lifecycle and due dates stay human.
  val humanOnly = allCmds(s, c => all {
    c.kind == "propose" implies c.via == NONE,
    (c.kind == "revise" and c.timing.due != c.prev.due) implies c.via == NONE,
    (c.kind == "create" and c.timing.due != 0) implies c.via == NONE,
  })

  // Single resolution, and a closed suggestion stays closed.
  val singleResolution = s.sugs.keys().forall(i =>
    s.resolutions.getOrElse(i, 0) == (if (s.sugs.get(i).status == Pending) 0 else 1))
  val statusMonotone = prev.sugs.keys().forall(i =>
    s.sugs.keys().contains(i) and
    (prev.sugs.get(i).status != Pending implies s.sugs.get(i).status == prev.sugs.get(i).status))

  // Round trip: Accepted iff the applied body is the Δ, Amended iff not.
  val acceptanceExact = allSugs(s, g => all {
    g.status == Accepted implies g.applied == g.change,
    g.status == Amended implies g.applied != g.change,
  })

  // Receipt isolation: evidence cites operator custody only, and the two
  // receipt maps share one event-ID space without overlap.
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

  // Reasons survive closure.
  val reasonsSurvive = allSugs(s, g =>
    (g.status == Declined or g.status == Withdrawn) implies
      (g.rationale == NONE or s.sugArtifacts.keys().contains(g.rationale)))

  // Superseded only ever applies to creates whose task now exists.
  val supersededSound = allSugs(s, g =>
    g.status == Superseded implies (g.kind == KCreate and s.tasks.get(g.task).exists))

  val safety = all {
    tasksFoldLog, suggesterLeavesTasks, facetIndependence, traceability,
    delegatedWithinLimits, budgetRespected, revocationEffective, humanOnly,
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
  val noDelegatedMove = allCmds(s, c => not(c.via != NONE and c.kind == "revise" and c.prev.slot != 0))
  val noDelegatedCreate = allCmds(s, c => not(c.via != NONE and c.kind == "create"))
  val noExhaustedBudget = s.delegations.keys().forall(i => s.delegations.get(i).used < s.delegations.get(i).budget)
  val noUsedThenRevoked = s.delegations.keys().forall(i =>
    not(s.delegations.get(i).used > 0 and s.delegations.get(i).grantEndedSeq != NEVER))
}
