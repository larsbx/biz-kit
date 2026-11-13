import ResearchExchange.Closure
import ResearchExchangeBridge.Encoding
import Std.Data.String.ToNat

set_option autoImplicit false

namespace ResearchExchangeBridge

open ResearchExchange

/-- The immutable MCP admission receipt, before hashes are interpreted. String
identities are represented losslessly; authenticity and digest truth are outside
this datatype. The generation is the admitted catalog generation. -/
structure ReceiptBinding where
  contributor : String
  library : String
  engine : String
  source_revision : String
  source_snapshot_sha256 : String
  generation : Nat
  target : String
  artifact_sha256 : String
  environment_sha256 : String
  policy_sha256 : String
  core_revision : String
  core_source_sha256 : String
  deriving DecidableEq, Repr

def sourceFields (b : ReceiptBinding) : List String :=
  [b.contributor, b.library, b.engine, b.source_revision, b.source_snapshot_sha256,
   b.target, b.artifact_sha256, b.environment_sha256, b.policy_sha256,
   b.core_revision, b.core_source_sha256, Nat.repr b.generation]

def projectBinding (b : ReceiptBinding) : Binding :=
  { target := Encoding.text b.target
    input := Encoding.fields (sourceFields b)
    environment := Encoding.text b.environment_sha256
    policy := Encoding.text b.policy_sha256 }

def projectCandidate (b : ReceiptBinding) : Candidate :=
  { worker := Encoding.text b.contributor, generation := b.generation
    binding := projectBinding b, artifact := Encoding.text b.artifact_sha256
    submittedAt := 0, leaseExpires := 1 }

theorem sourceFields_injective (a b : ReceiptBinding) (h : sourceFields a = sourceFields b) :
    a = b := by
  cases a
  cases b
  simp_all [sourceFields]

theorem projectBinding_injective (a b : ReceiptBinding) (h : projectBinding a = projectBinding b) :
    a = b := by
  have hi := congrArg Binding.input h
  exact sourceFields_injective a b (Encoding.fields_injective _ _ hi)

theorem projectCandidate_injective (a b : ReceiptBinding)
    (h : projectCandidate a = projectCandidate b) : a = b := by
  exact projectBinding_injective a b (congrArg Candidate.binding h)

inductive Phase where
  | submitted | accepted | rejected
  deriving DecidableEq, Repr

inductive Verdict where
  | accepted | rejected | inconclusive
  deriving DecidableEq, Repr

structure Config where
  expected : ReceiptBinding
  profile : String
  verifier : String
  reward : Nat
  deriving DecidableEq, Repr

/-- This is a fresh transaction snapshot: `verifier_*` and `requester_*` must be
joined from current authority/grant rows, not copied from the historical job.
The theorem does not assert that a database query actually performs that join. -/
structure Row where
  binding : ReceiptBinding
  phase : Phase
  version : Nat
  verifier_enabled : Bool
  authority_epoch : Nat
  requester_enabled : Bool
  requester_epoch : Nat
  payouts : Nat
  funder : Nat
  escrow : Nat
  balance_a : Nat
  balance_b : Nat
  settlement : Bool
  refund_amount : Option Nat
  deriving DecidableEq, Repr

structure Identity where
  authenticated : Bool
  principal : String
  requester : String
  deriving DecidableEq, Repr

structure Prepared where
  binding : ReceiptBinding
  profile : String
  version : Nat
  authority_epoch : Nat
  requester_epoch : Nat
  checked : Bool
  deriving DecidableEq, Repr

def projectConfig (cfg : Config) : Adapter.Config :=
  { reward := { expected := projectBinding cfg.expected, reward := cfg.reward
                workerA := Encoding.text cfg.expected.contributor
                workerB := Encoding.text cfg.expected.contributor + 1 }
    verifier := Encoding.text cfg.verifier, profile := Encoding.text cfg.profile }

def projectPhase : Phase → Reward.Phase
  | .submitted => .submitted
  | .accepted => .accepted
  | .rejected => .rejected

def projectVerdict : Verdict → Closure.Verdict
  | .accepted => .accepted
  | .rejected => .definitiveRejection
  | .inconclusive => .inconclusive

def projectRow (s : Row) : Closure.State :=
  { adapter := {
      reward := {
        now := 0, generation := s.binding.generation
        owner := Encoding.text s.binding.contributor, expires := 1
        phase := projectPhase s.phase, candidate := some (projectCandidate s.binding)
        payouts := s.payouts, funder := s.funder, escrow := s.escrow
        balanceA := s.balance_a, balanceB := s.balance_b }
      version := s.version, verifierEnabled := s.verifier_enabled
      verifierEpoch := s.authority_epoch
      settlement := if s.settlement then some (projectCandidate s.binding) else none }
    refund := s.refund_amount.map (fun amount => ⟨projectCandidate s.binding, amount⟩) }

/-- The additional requester grant fence is explicit in the projection.
`authenticated` itself is an authenticated host assertion, never a tool argument. -/
def projectIdentity (s : Row) (who : Identity) (p : Prepared) : Adapter.RequestIdentity :=
  { authenticated := who.authenticated && s.requester_enabled &&
      decide (p.requester_epoch = s.requester_epoch) &&
      decide (who.requester = s.binding.contributor)
    principal := Encoding.text who.principal }

def projectPrepared (p : Prepared) : Adapter.Prepared :=
  { candidate := projectCandidate p.binding, profile := Encoding.text p.profile
    version := p.version, authorityEpoch := p.authority_epoch, checked := p.checked }

/-- Admission/current-authority guards are checked against the fresh snapshot.
The exact escrow condition deliberately describes one original prefunded slot.
This slice issues no service credit and does not model general worker leases. -/
def ready (cfg : Config) (s : Row) (who : Identity) (p : Prepared) : Prop :=
  s.binding = cfg.expected ∧ p.binding = s.binding ∧
  who.authenticated = true ∧ who.principal = cfg.verifier ∧
  who.requester = s.binding.contributor ∧ s.requester_enabled = true ∧
  p.requester_epoch = s.requester_epoch ∧ s.verifier_enabled = true ∧
  p.authority_epoch = s.authority_epoch ∧ p.checked = true ∧
  p.profile = cfg.profile ∧ p.version = s.version ∧
  s.phase = .submitted ∧ s.payouts = 0 ∧ s.settlement = false ∧
  s.refund_amount = none ∧ s.escrow = cfg.reward ∧ 0 < cfg.reward

instance (cfg : Config) (s : Row) (who : Identity) (p : Prepared) :
    Decidable (ready cfg s who p) := by
  unfold ready
  infer_instance

/-- Concrete row arithmetic, independently specified from Closure.decide.
The executable checker compares this update to the existing core projection. -/
def step (cfg : Config) (s : Row) (who : Identity) (p : Prepared) (v : Verdict) : Row :=
  if ready cfg s who p then
    match v with
    | .accepted =>
      { s with phase := .accepted, version := s.version + 1, payouts := 1
               escrow := s.escrow - cfg.reward, balance_a := s.balance_a + cfg.reward
               settlement := true }
    | .rejected =>
      { s with phase := .rejected, version := s.version + 1
               funder := s.funder + s.escrow, escrow := 0
               refund_amount := some s.escrow }
    | .inconclusive => s
  else s

/-- Refusals correspond to an allowed stutter. We prove forward simulation of
these concrete guarded operations, not reverse equivalence on corrupt rows. -/
def admittedVerdict (cfg : Config) (s : Row) (who : Identity) (p : Prepared) (v : Verdict) :
    Closure.Verdict := if ready cfg s who p then projectVerdict v else .inconclusive

def coreResult (cfg : Config) (s : Row) (who : Identity) (p : Prepared) (v : Verdict) :
    Closure.State :=
  Closure.decide (projectConfig cfg) (projectRow s) (projectIdentity s who p)
    (projectPrepared p) (admittedVerdict cfg s who p v)

end ResearchExchangeBridge
