import Init

/-!
# Lease fencing safety abstraction

One operational effect belongs to one signed EventStore run intent. A single
PostgreSQL CAS version protects the currently live execution lease; an epoch
fences stale workers after cancellation or adoption. This abstraction does
NOT prove actual PostgreSQL isolation, receipt verification, a container
runtime, cross-host finality, or exactly-once external side effects.

There is no mathematical use of backend vendor, model, Podman, or Docker.
-/

namespace BizKitEventProofs

structure Lease where
  version : Nat
  epoch : Nat
  holder : Option Nat
  cancelled : Bool

def leaseInitial : Lease :=
  { version := 0, epoch := 0, holder := none, cancelled := false }

def claimed (s : Lease) (worker : Nat) : Lease :=
  { s with
    version := s.version + 1
    epoch := s.epoch + 1
    holder := some worker }

def cancelled (s : Lease) : Lease :=
  { s with
    version := s.version + 1
    epoch := s.epoch + 1
    holder := none
    cancelled := true }

/-- SQL CAS requires exact row_version, no holder, and a non-cancelled run. -/
def attemptClaim (s : Lease) (expected worker : Nat) : Option Lease :=
  if s.version = expected ∧ s.holder = none ∧ s.cancelled = false then
    some (claimed s worker)
  else none

/-- Tokens and generation are checked against the current, committed lease. -/
def validReply (s : Lease) (worker expectedEpoch : Nat) : Prop :=
  s.cancelled = false ∧
  s.holder = some worker ∧
  s.epoch = expectedEpoch

theorem successful_claim (s : Lease) (worker : Nat)
    (idle : s.holder = none) (openRun : s.cancelled = false) :
    attemptClaim s s.version worker = some (claimed s worker) := by
  simp [attemptClaim, idle, openRun]

theorem stale_version_cannot_claim (s : Lease) (expected worker : Nat)
    (stale : s.version ≠ expected) :
    attemptClaim s expected worker = none := by
  simp [attemptClaim, stale]

/-- Once worker 1 has won, worker 2 cannot claim that same version. -/
theorem second_claim_rejected (s : Lease) (firstWorker secondWorker : Nat) :
    attemptClaim (claimed s firstWorker) s.version secondWorker = none := by
  simp [attemptClaim, claimed]

/-- A cancellation invalidates every earlier attempt generation. -/
theorem cancellation_fences (s : Lease) (worker oldEpoch : Nat) :
    ¬ validReply (cancelled s) worker oldEpoch := by
  simp [validReply, cancelled]

/-- A successfully claimed effect has exactly the selected live holder. -/
theorem claim_has_unique_holder (s : Lease) (worker another : Nat)
    (different : another ≠ worker) :
    (claimed s worker).holder ≠ some another := by
  simp [claimed, Ne.symm different]

end BizKitEventProofs
