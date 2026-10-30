import Init

/-!
# Dispatch operations: abstract safety contracts

A transition is admitted only for the actor's organization, an allowed
source/action pair and an optional matching expected version. One accepted
transition atomically changes status, increments the version, and appends an
audit event. Failed attempts do not change the state.

This is a *specification and kernel proof*, not a proof that Ecto/Ash acquires
the right lock, commits the event in the same SQL transaction, or persists an
HTTP idempotency claim. Those are refinement obligations exercised by the
Dispatch PostgreSQL integration tests.
-/

namespace BizKitDispatch

inductive Status where
  | planned | active | completed | cancelled
  deriving DecidableEq, Repr

inductive Action where
  | activate | complete | cancel
  deriving DecidableEq, Repr

def permitted : Status → Action → Bool
  | .planned, .activate => true
  | .planned, .cancel => true
  | .active, .complete => true
  | .active, .cancel => true
  | _, _ => false

structure Trip where
  organization : Nat
  status : Status
  version : Nat
  ended : Bool
  events : List Action
  deriving Repr

def commit (s : Trip) (a : Action) : Trip :=
  { s with
    status := match a with
      | .activate => .active
      | .complete => .completed
      | .cancel => .cancelled
    version := s.version + 1
    ended := if a = .activate then s.ended else true
    events := s.events ++ [a] }

def admitted (s : Trip) (actorOrganization : Nat)
    (a : Action) (expected : Option Nat) : Prop :=
  s.organization = actorOrganization ∧
  permitted s.status a = true ∧
  (expected = none ∨ expected = some s.version)

/-- The option represents the entire SQL transaction, including the audit event. -/
def transition (s : Trip) (actorOrganization : Nat)
    (a : Action) (expected : Option Nat) : Option Trip := by
  classical
  exact if admitted s actorOrganization a expected then some (commit s a) else none

theorem admitted_commits (s : Trip) (org : Nat) (a : Action) (v : Option Nat)
    (h : admitted s org a v) :
    transition s org a v = some (commit s a) := by
  simp [transition, h]

theorem refused_is_noop (s : Trip) (org : Nat) (a : Action) (v : Option Nat)
    (h : ¬ admitted s org a v) :
    transition s org a v = none := by
  simp [transition, h]

theorem foreign_organization_refused (s : Trip) (org : Nat) (a : Action)
    (v : Option Nat) (different : s.organization ≠ org) :
    transition s org a v = none := by
  apply refused_is_noop
  intro h
  exact different h.1

theorem terminal_states_refused (s : Trip) (org : Nat) (a : Action)
    (v : Option Nat) (terminal : s.status = .completed ∨ s.status = .cancelled) :
    transition s org a v = none := by
  apply refused_is_noop
  intro h
  obtain ⟨_, allowed, _⟩ := h
  rcases terminal with hs | hs
  · cases a <;> simp [hs, permitted] at allowed
  · cases a <;> simp [hs, permitted] at allowed

theorem stale_version_refused (s : Trip) (org : Nat) (a : Action) (v : Nat)
    (stale : v ≠ s.version) :
    transition s org a (some v) = none := by
  apply refused_is_noop
  intro h
  rcases h.2.2 with hn | hv
  · cases hn
  · exact stale (Option.some.inj hv)

theorem commit_preserves_organization (s : Trip) (a : Action) :
    (commit s a).organization = s.organization := rfl

theorem commit_increments_version (s : Trip) (a : Action) :
    (commit s a).version = s.version + 1 := rfl

theorem commit_appends_exactly_one_audit (s : Trip) (a : Action) :
    (commit s a).events = s.events ++ [a] := rfl

theorem complete_or_cancel_sets_end (s : Trip) :
    (commit s .complete).ended = true ∧ (commit s .cancel).ended = true := by
  simp [commit]

/-- The complete identity is method + target + canonical body, not body alone. -/
structure HttpRequest where
  method : Nat
  target : Nat
  bodyDigest : Nat
  deriving DecidableEq, Repr

structure Claim where
  tenant : Nat
  role : Nat
  key : Nat
  request : HttpRequest
  deriving DecidableEq, Repr

def mayReplay (saved incoming : Claim) : Prop :=
  saved = incoming

theorem target_change_cannot_replay (saved incoming : Claim)
    (different : saved.request.target ≠ incoming.request.target) :
    ¬ mayReplay saved incoming := by
  intro equalClaim
  exact different (congrArg (fun c : Claim => c.request.target) equalClaim)

theorem method_change_cannot_replay (saved incoming : Claim)
    (different : saved.request.method ≠ incoming.request.method) :
    ¬ mayReplay saved incoming := by
  intro equalClaim
  exact different (congrArg (fun c : Claim => c.request.method) equalClaim)

theorem body_change_cannot_replay (saved incoming : Claim)
    (different : saved.request.bodyDigest ≠ incoming.request.bodyDigest) :
    ¬ mayReplay saved incoming := by
  intro equalClaim
  exact different (congrArg (fun c : Claim => c.request.bodyDigest) equalClaim)

theorem role_change_cannot_replay (saved incoming : Claim)
    (different : saved.role ≠ incoming.role) :
    ¬ mayReplay saved incoming := by
  intro equalClaim
  exact different (congrArg Claim.role equalClaim)

theorem tenant_change_cannot_replay (saved incoming : Claim)
    (different : saved.tenant ≠ incoming.tenant) :
    ¬ mayReplay saved incoming := by
  intro equalClaim
  exact different (congrArg Claim.tenant equalClaim)

end BizKitDispatch
