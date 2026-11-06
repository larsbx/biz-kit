import Std

namespace ResearchExchange.Reservation

inductive Phase where
  | idle | reserved | running | cancelling | stopped | settled
  deriving DecidableEq, BEq, Repr

structure State where
  phase : Phase
  available : Nat
  held : Nat
  spent : Nat
  deriving DecidableEq, BEq, Repr

def initial (credit : Nat) : State :=
  { phase := .idle, available := credit, held := 0, spent := 0 }

def reserve (s : State) (cap : Nat) : State :=
  if s.phase = .idle ∧ cap ≤ s.available then
    { s with phase := .reserved, available := s.available - cap, held := s.held + cap }
  else s

def start (s : State) : State :=
  if s.phase = .reserved then { s with phase := .running } else s

def cancel (s : State) : State :=
  match s.phase with
  | .reserved => { s with phase := .stopped }
  | .running => { s with phase := .cancelling }
  | _ => s

/-- Trust means the runtime has authenticated a completed stop acknowledgment.
    This is an environmental assumption, not a proof about a physical process. -/
def stop (s : State) (trusted : Bool) : State :=
  if trusted = true ∧ (s.phase = .running ∨ s.phase = .cancelling) then
    { s with phase := .stopped }
  else s

def settle (s : State) (cost : Nat) : State :=
  if s.phase = .stopped ∧ cost ≤ s.held then
    { phase := .settled, available := s.available + (s.held - cost),
      held := 0, spent := s.spent + cost }
  else s

inductive Action where
  | reserve (cap : Nat)
  | start
  | cancel
  | stop (trusted : Bool)
  | settle (cost : Nat)
  deriving DecidableEq, Repr

def step (s : State) : Action → State
  | .reserve cap => reserve s cap
  | .start => start s
  | .cancel => cancel s
  | .stop t => stop s t
  | .settle cost => settle s cost

def total (s : State) : Nat := s.available + s.held + s.spent

theorem reserve_preserves_total (s : State) (cap : Nat) :
    total (reserve s cap) = total s := by
  unfold reserve
  split
  · rename_i h
    have := h.2
    simp only [total]
    omega
  · rfl

theorem settle_preserves_total (s : State) (cost : Nat) :
    total (settle s cost) = total s := by
  unfold settle
  split
  · rename_i h
    have := h.2
    simp only [total]
    omega
  · rfl

theorem step_preserves_total (s : State) (a : Action) :
    total (step s a) = total s := by
  cases a with
  | reserve cap => exact reserve_preserves_total s cap
  | start => simp only [step, start]; split <;> rfl
  | cancel => simp only [step, cancel]; split <;> rfl
  | stop t => simp only [step, stop]; split <;> rfl
  | settle cost => exact settle_preserves_total s cost

theorem insufficient_balance_refused (s : State) (cap : Nat) (h : s.available < cap) :
    reserve s cap = s := by
  have : ¬ cap ≤ s.available := by omega
  simp [reserve, this]

theorem running_cancel_retains_hold (s : State) (h : s.phase = .running) :
    (cancel s).phase = .cancelling ∧ (cancel s).held = s.held ∧
      (cancel s).available = s.available ∧ (cancel s).spent = s.spent := by
  simp [cancel, h]

theorem untrusted_stop_refused (s : State) : stop s false = s := by
  simp [stop]

theorem running_cannot_settle (s : State) (cost : Nat)
    (h : s.phase = .running ∨ s.phase = .cancelling) : settle s cost = s := by
  rcases h with h | h <;> simp [settle, h]

theorem settlement_requires_stop (s : State) (cost : Nat)
    (h : settle s cost ≠ s) : s.phase = .stopped := by
  unfold settle at h
  split at h
  · rename_i hg
    exact hg.1
  · contradiction

/-- No action can release held credit while a process is running or cancellation
    is waiting for a stop acknowledgment. A trusted stop changes phase only. -/
theorem no_refund_while_running (s : State) (a : Action)
    (h : s.phase = .running ∨ s.phase = .cancelling) :
    (step s a).available = s.available ∧ (step s a).held = s.held := by
  rcases h with h | h <;> cases a <;>
    simp [step, reserve, start, cancel, stop, settle, h]
  all_goals split <;> exact ⟨rfl, rfl⟩

theorem settlement_idempotent (s : State) (cost : Nat) :
    settle (settle s cost) cost = settle s cost := by
  unfold settle
  split
  · simp
  · rfl

theorem settled_terminal (s : State) (a : Action) (h : s.phase = .settled) :
    step s a = s := by
  cases a <;> simp [step, reserve, start, cancel, stop, settle, h]

inductive Reachable (credit : Nat) : State → Prop
  | initial : Reachable credit (initial credit)
  | next {s : State} (h : Reachable credit s) (a : Action) : Reachable credit (step s a)

theorem reachable_conservation (credit : Nat) (s : State)
    (hr : Reachable credit s) : total s = credit := by
  induction hr with
  | initial => simp [total, initial]
  | next hr action ih => rw [step_preserves_total, ih]

end ResearchExchange.Reservation
