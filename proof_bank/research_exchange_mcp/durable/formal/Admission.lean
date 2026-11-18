import ResearchExchange.Reward

namespace ResearchExchange.MCPDurable

structure Admission where
  worker : Nat
  generation : Nat
  binding : Binding
  artifact : Nat
  epoch : Nat
  deriving DecidableEq

structure Authority where
  worker : Nat
  epoch : Nat
  enabled : Bool

structure Row where
  request : Admission
  submittedAt : Nat
  leaseExpires : Nat
  deriving DecidableEq

def Row.candidate (row : Row) : Candidate :=
  ⟨row.request.worker, row.request.generation, row.request.binding, row.request.artifact,
    row.submittedAt, row.leaseExpires⟩

/-- Projection of the durable admission row into the selected core's reward state.
    The credential epoch is retained in the row because Reward.Candidate has no epoch. -/
def Represents (row : Row) (s : Reward.State) : Prop :=
  s.phase = .submitted ∧ s.candidate = some row.candidate

def authorized (g : Authority) (a : Admission) : Bool :=
  g.enabled && decide (g.worker = a.worker) && decide (g.epoch = a.epoch)

def admit (cfg : Reward.Config) (s : Reward.State) (g : Authority) (a : Admission) :
    Option Row × Reward.State :=
  if authorized g a then
    let next := Reward.submit cfg s a.worker a.generation a.binding a.artifact
    if next = s then (none, s) else (some ⟨a, s.now, s.expires⟩, next)
  else (none, s)

theorem committed_admission (cfg : Reward.Config) (s next : Reward.State)
    (g : Authority) (a : Admission) (row : Row)
    (h : admit cfg s g a = (some row, next)) :
    Represents row next ∧ row.request = a ∧ a.epoch = g.epoch ∧
    a.worker = g.worker ∧ g.enabled = true ∧ a.binding = cfg.expected ∧
    next = Reward.submit cfg s a.worker a.generation a.binding a.artifact ∧
    next.payouts = s.payouts ∧ next.escrow = s.escrow := by
  simp only [admit] at h
  split at h
  · rename_i auth
    split at h
    · simp at h
    · rename_i changed
      have guard : s.phase = .leased ∧ a.worker = s.owner ∧ a.generation = s.generation ∧
          s.now < s.expires ∧ a.binding = cfg.expected ∧ s.candidate = none ∧
          Reward.participant cfg a.worker := by
        by_cases valid : s.phase = .leased ∧ a.worker = s.owner ∧ a.generation = s.generation ∧
            s.now < s.expires ∧ a.binding = cfg.expected ∧ s.candidate = none ∧
            Reward.participant cfg a.worker
        · exact valid
        · exact False.elim (changed (by simp [Reward.submit, valid]))
      simp only [Prod.mk.injEq, Option.some.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      have ha : g.enabled = true ∧ g.worker = a.worker ∧ g.epoch = a.epoch := by
        simpa [authorized, Bool.and_eq_true, and_assoc] using auth
      simp only [Reward.submit, ite_eq_left guard]
      exact ⟨⟨rfl, rfl⟩, trivial, ha.2.2.symm, ha.2.1.symm, ha.1, guard.2.2.2.2.1,
        trivial, trivial, trivial⟩
  · simp at h

theorem refusal_stutters (cfg : Reward.Config) (s next : Reward.State)
    (g : Authority) (a : Admission) (h : admit cfg s g a = (none, next)) :
    next = s := by
  simp only [admit] at h
  split at h
  · split at h <;> simp_all
  · simp_all

inductive Outcome where
  | passed | rejected | inconclusive
  deriving DecidableEq

/-- A definitive disposition belongs to the observation layer. Its core projection
    remains submitted. The caller supplies the authenticated checker result. -/
def record (row : Row) (g : Authority) (seen : Option Outcome) (outcome : Outcome) :
    Option Outcome :=
  if authorized g row.request && seen.isNone && decide (outcome ≠ .inconclusive)
  then some outcome else seen

theorem inconclusive_stutters (row : Row) (g : Authority) (seen : Option Outcome) :
    record row g seen .inconclusive = seen := by
  simp [record]

theorem stale_epoch_stutters (row : Row) (g : Authority) (seen : Option Outcome)
    (o : Outcome) (h : g.epoch ≠ row.request.epoch) :
    record row g seen o = seen := by
  simp [record, authorized, h]

theorem terminal_immutable (row : Row) (g : Authority) (old o : Outcome) :
    record row g (some old) o = some old := by
  simp [record]

end ResearchExchange.MCPDurable
