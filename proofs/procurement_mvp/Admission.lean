import Std

namespace ProcurementAdmission

-- An admission-boundary abstraction, not a proof of PostgreSQL or the host.
structure State where
  active : Bool
  grant : Nat
  version : Nat
  deriving DecidableEq, Repr

def admit (s : State) (grant expected : Nat) (retry : Bool) : State :=
  if s.active = false then s
  else if grant ≠ s.grant then s
  else if retry = true then s
  else if expected ≠ s.version then s
  else { s with version := s.version + 1 }

def revoke (s : State) : State :=
  { s with active := false, grant := s.grant + 1 }

theorem revoked_denied (s : State) (g v : Nat) (r : Bool) :
    admit (revoke s) g v r = revoke s := by
  simp [admit, revoke]

theorem stale_grant_denied (s : State) (g v : Nat) (r : Bool)
    (h : g ≠ s.grant) : admit s g v r = s := by
  simp [admit, h]

theorem retry_inert (s : State) (g v : Nat) :
    admit s g v true = s := by
  simp [admit]

theorem stale_version_denied (s : State) (g v : Nat) (r : Bool)
    (h : v ≠ s.version) : admit s g v r = s := by
  simp [admit, h]

theorem admitted_increment (s : State) (h : s.active = true) :
    admit s s.grant s.version false = { s with version := s.version + 1 } := by
  simp [admit, h]

theorem competing_version_cannot_commit_twice (s : State) (h : s.active = true) :
    admit (admit s s.grant s.version false) s.grant s.version false =
      admit s s.grant s.version false := by
  have hn : s.version ≠ s.version + 1 := Nat.ne_of_lt (Nat.lt_succ_self s.version)
  simp [admit, h, hn]

#print axioms revoked_denied
#print axioms stale_grant_denied
#print axioms retry_inert
#print axioms stale_version_denied
#print axioms admitted_increment
#print axioms competing_version_cannot_commit_twice
end ProcurementAdmission
