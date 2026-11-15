import Init

/-!
# Proof Bank AT-1/AT-2: second authorization at the agent launch boundary

This is an ABSTRACT model of TaskCore.AgentRuns.authorized?/3,
AgentCore.Preflight.prepare/4, the trusted profile registry and
TaskCore.Dispatcher.deliver/2. It models current-state authorization
at two observations separated by a durable CAS claim, followed by an
explicit host observation of launch-lease validity.

The real Elixir/SQL implementation, signed-event replay, clocks and
external side effects are NOT verified by these theorems.
Neither observation is atomic with an external launch. In particular,
these theorems make no claim about authority changes after the observations.
-/

namespace BizKitAgentTask

structure Authority where
  operatorActive : Bool
  suggesterActive : Bool
  readGrant : Bool
  executeGrant : Bool
  profileApproved : Bool
  taskVersion : Nat
  pinnedTaskVersion : Nat
  currentProfileDigest : Nat
  pinnedProfileDigest : Nat
  deriving Repr, DecidableEq

def eligible (s : Authority) : Bool :=
  s.operatorActive && s.suggesterActive && s.readGrant &&
  s.executeGrant && s.profileApproved &&
  (s.taskVersion == s.pinnedTaskVersion) &&
  (s.currentProfileDigest == s.pinnedProfileDigest)

inductive Decision where
  | refused
  | fenced
  | blocked
  | launched
  deriving Repr, DecidableEq

/-- An authorized plan may launch only after its durable claim and a *fresh*
    second authorization. The recheck is not optional even when a claim exists. -/
def decideLaunch (before after : Authority) (claimed : Bool) : Decision :=
  if eligible before then
    if claimed then
      if eligible after then .launched else .fenced
    else .refused
  else .refused

theorem refused_before_claim (before after : Authority)
    (h : eligible before = false) :
    decideLaunch before after true = .refused := by
  simp [decideLaunch, h]

theorem denied_after_claim_fences (before after : Authority)
    (hBefore : eligible before = true) (hAfter : eligible after = false) :
    decideLaunch before after true = .fenced := by
  simp [decideLaunch, hBefore, hAfter]

theorem no_claim_never_launches (before after : Authority) :
    decideLaunch before after false ≠ .launched := by
  cases h : eligible before <;> simp [decideLaunch, h]

theorem launch_requires_fresh_authority (before after : Authority) (claimed : Bool)
    (h : decideLaunch before after claimed = .launched) :
    eligible before = true ∧ eligible after = true ∧ claimed = true := by
  cases hBefore : eligible before <;>
    cases hAfter : eligible after <;>
    cases claimed <;>
    simp [decideLaunch, hBefore, hAfter] at h ⊢

/-- A precisely pinned valid snapshot is not a durable authorization token. -/
def valid : Authority :=
  { operatorActive := true
    suggesterActive := true
    readGrant := true
    executeGrant := true
    profileApproved := true
    taskVersion := 2
    pinnedTaskVersion := 2
    currentProfileDigest := 9
    pinnedProfileDigest := 9 }

def revokedOperator : Authority := { valid with operatorActive := false }
def changedTask : Authority := { valid with taskVersion := 3 }
def changedProfile : Authority := { valid with currentProfileDigest := 10 }

theorem operator_revoked_fences : decideLaunch valid revokedOperator true = .fenced := by
  decide

theorem task_changed_fences : decideLaunch valid changedTask true = .fenced := by
  decide

theorem profile_changed_fences : decideLaunch valid changedProfile true = .fenced := by
  decide

/-- Unsafe control: a pre-claim decision is reused without fresh checking. -/
def uncheckedLaunch (before : Authority) (claimed : Bool) : Decision :=
  if eligible before && claimed then .launched else .refused

theorem missing_recheck_counterexample :
    uncheckedLaunch valid true = .launched ∧
    decideLaunch valid revokedOperator true = .fenced := by
  decide

/-- A current authority snapshot does not certify that the lease survived
    the authorization wait. Invalid leases remain blocked for reconciliation;
    this decision does not assert that cancellation or termination completed. -/
def decideValidatedLaunch (before after : Authority) (claimed leaseValid : Bool) : Decision :=
  match decideLaunch before after claimed with
  | .launched => if leaseValid then .launched else .blocked
  | other => other

theorem invalid_lease_never_launches (before after : Authority) (claimed : Bool) :
    decideValidatedLaunch before after claimed false ≠ .launched := by
  cases h : decideLaunch before after claimed <;>
    simp [decideValidatedLaunch, h]

theorem validated_launch_requires_guards
    (before after : Authority) (claimed leaseValid : Bool)
    (h : decideValidatedLaunch before after claimed leaseValid = .launched) :
    eligible before = true ∧ eligible after = true ∧ claimed = true ∧ leaseValid = true := by
  cases hDecision : decideLaunch before after claimed <;>
    cases leaseValid <;>
    simp [decideValidatedLaunch, hDecision] at h
  have guards := launch_requires_fresh_authority before after claimed hDecision
  exact ⟨guards.1, guards.2.1, guards.2.2, rfl⟩

/-- Unsafe control: even the old two-observation guard permits launch when
    the lease expires or is cancelled during its second authorization read. -/
theorem missing_lease_validation_counterexample :
    decideLaunch valid valid true = .launched ∧
    decideValidatedLaunch valid valid true false = .blocked := by
  decide

end BizKitAgentTask
