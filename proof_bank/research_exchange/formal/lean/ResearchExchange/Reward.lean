import ResearchExchange.Binding

namespace ResearchExchange.Reward

structure Config where
  expected : Binding
  reward : Nat
  workerA : Nat
  workerB : Nat
  deriving DecidableEq, Repr

inductive Phase where
  | open | leased | submitted | accepted | rejected
  deriving DecidableEq, BEq, Repr

structure State where
  now : Nat
  generation : Nat
  owner : Nat
  expires : Nat
  phase : Phase
  candidate : Option Candidate
  payouts : Nat
  funder : Nat
  escrow : Nat
  balanceA : Nat
  balanceB : Nat
  deriving DecidableEq, BEq, Repr

def initial (cfg : Config) (funder balanceA balanceB : Nat) : State :=
  { now := 0, generation := 0, owner := cfg.workerA, expires := 0,
    phase := .open, candidate := none, payouts := 0,
    funder, escrow := cfg.reward, balanceA, balanceB }

def participant (cfg : Config) (worker : Nat) : Prop :=
  worker = cfg.workerA ∨ worker = cfg.workerB

instance (cfg : Config) (worker : Nat) : Decidable (participant cfg worker) :=
  inferInstanceAs (Decidable (worker = cfg.workerA ∨ worker = cfg.workerB))

def tick (s : State) (delta : Nat) : State :=
  if s.phase = .rejected then s else { s with now := s.now + delta }

def lease (cfg : Config) (s : State) (worker deadline : Nat) : State :=
  if participant cfg worker ∧ s.now < deadline ∧ s.candidate = none ∧
      (s.phase = .open ∨ (s.phase = .leased ∧ s.expires ≤ s.now)) then
    { s with
      phase := .leased
      generation := s.generation + 1
      owner := worker
      expires := deadline }
  else s

def submit (cfg : Config) (s : State) (worker generation : Nat)
    (binding : Binding) (artifact : Nat) : State :=
  if s.phase = .leased ∧ worker = s.owner ∧ generation = s.generation ∧
      s.now < s.expires ∧ binding = cfg.expected ∧ s.candidate = none ∧
      participant cfg worker then
    { s with
      phase := .submitted
      candidate := some {
        worker, generation, binding, artifact
        submittedAt := s.now
        leaseExpires := s.expires } }
  else s

/-- `trusted` is supplied only by the authenticated verification adapter.
    The model does not establish the authenticity of this input. -/
def accept (cfg : Config) (s : State) (trusted : Bool) (evidence : Candidate) : State :=
  if s.phase = .submitted ∧ trusted = true ∧ s.candidate = some evidence ∧
      evidence.binding = cfg.expected ∧ participant cfg evidence.worker ∧
      s.payouts = 0 ∧ cfg.reward ≤ s.escrow then
    { s with
      phase := .accepted
      payouts := 1
      escrow := s.escrow - cfg.reward
      balanceA := if evidence.worker = cfg.workerA then s.balanceA + cfg.reward else s.balanceA
      balanceB := if evidence.worker = cfg.workerA then s.balanceB else s.balanceB + cfg.reward }
  else s

inductive Action where
  | tick (delta : Nat)
  | lease (worker deadline : Nat)
  | submit (worker generation : Nat) (binding : Binding) (artifact : Nat)
  | accept (trusted : Bool) (evidence : Candidate)
  deriving DecidableEq, Repr

def step (cfg : Config) (s : State) : Action → State
  | .tick d => tick s d
  | .lease w d => lease cfg s w d
  | .submit w g b a => submit cfg s w g b a
  | .accept t e => accept cfg s t e

/-- Conservation is scoped to one already funded reward slot and two participants. -/
def total (s : State) : Nat := s.funder + s.escrow + s.balanceA + s.balanceB

def admittedValid (cfg : Config) (s : State) : Prop :=
  ∀ c, s.candidate = some c →
    c.binding = cfg.expected ∧ c.submittedAt < c.leaseExpires ∧ participant cfg c.worker

def safe (cfg : Config) (s : State) : Prop :=
  s.payouts ≤ 1 ∧ admittedValid cfg s

/-- Every identifier including artifact and original timing is immutable once admitted. -/
theorem candidate_immutable (cfg : Config) (s : State) (a : Action) (c : Candidate)
    (h : s.candidate = some c) : (step cfg s a).candidate = some c := by
  cases a with
  | tick d => simp only [step, tick]; split <;> exact h
  | lease w d => simp only [step, lease]; split <;> exact h
  | submit w g b artifact =>
    simp only [step, submit]
    split
    · rename_i guards
      have hn : s.candidate = none := guards.2.2.2.2.2.1
      rw [h] at hn
      contradiction
    · exact h
  | accept trusted evidence => simp only [step, accept]; split <;> exact h

theorem stale_generation_refused (cfg : Config) (s : State) (w g artifact : Nat)
    (binding : Binding) (h : g ≠ s.generation) :
    submit cfg s w g binding artifact = s := by
  simp [submit, h]

theorem wrong_binding_refused (cfg : Config) (s : State) (w g artifact : Nat)
    (binding : Binding) (h : binding ≠ cfg.expected) :
    submit cfg s w g binding artifact = s := by
  simp [submit, h]

theorem expired_submission_refused (cfg : Config) (s : State) (w g artifact : Nat)
    (binding : Binding) (h : s.expires ≤ s.now) :
    submit cfg s w g binding artifact = s := by
  have : ¬ s.now < s.expires := by omega
  simp [submit, this]

theorem untrusted_accept_refused (cfg : Config) (s : State) (e : Candidate) :
    accept cfg s false e = s := by
  simp [accept]

theorem wrong_evidence_refused (cfg : Config) (s : State) (e : Candidate)
    (h : s.candidate ≠ some e) : accept cfg s true e = s := by
  simp [accept, h]

theorem wrong_evidence_binding_refused (cfg : Config) (s : State) (t : Bool)
    (e : Candidate) (h : e.binding ≠ cfg.expected) : accept cfg s t e = s := by
  simp [accept, h]

theorem accept_requires_authority (cfg : Config) (s : State) (t : Bool) (e : Candidate)
    (h : accept cfg s t e ≠ s) :
    t = true ∧ s.candidate = some e ∧ e.binding = cfg.expected := by
  unfold accept at h
  split at h
  · rename_i guards
    exact ⟨guards.2.1, guards.2.2.1, guards.2.2.2.1⟩
  · contradiction

theorem paid_refuses_retry (cfg : Config) (s : State) (t : Bool) (e : Candidate)
    (h : s.payouts ≠ 0) : accept cfg s t e = s := by
  simp [accept, h]

theorem accept_idempotent (cfg : Config) (s : State) (t : Bool) (e : Candidate) :
    accept cfg (accept cfg s t e) t e = accept cfg s t e := by
  unfold accept
  split
  · simp
  · rfl

theorem accept_preserves_total (cfg : Config) (s : State) (t : Bool) (e : Candidate) :
    total (accept cfg s t e) = total s := by
  unfold accept
  split
  · rename_i guards
    have he : cfg.reward ≤ s.escrow := guards.2.2.2.2.2.2
    unfold total
    dsimp
    split <;> omega
  · rfl

theorem step_preserves_total (cfg : Config) (s : State) (a : Action) :
    total (step cfg s a) = total s := by
  cases a with
  | tick d => simp only [step, tick]; split <;> rfl
  | lease w d => simp only [step, lease]; split <;> rfl
  | submit w g b artifact => simp only [step, submit]; split <;> rfl
  | accept t e => exact accept_preserves_total cfg s t e

theorem step_preserves_safe (cfg : Config) (s : State) (a : Action)
    (hs : safe cfg s) : safe cfg (step cfg s a) := by
  rcases hs with ⟨hp, hv⟩
  cases a with
  | tick d => simp only [step, tick]; split <;> exact ⟨hp, hv⟩
  | lease w d => simp only [step, lease]; split <;> exact ⟨hp, hv⟩
  | submit w g b artifact =>
    simp only [step, submit]
    split
    · rename_i guards
      refine ⟨hp, ?_⟩
      intro c hc
      have hc' : Candidate.mk w g b artifact s.now s.expires = c :=
        Option.some.inj hc
      subst c
      exact ⟨guards.2.2.2.2.1, guards.2.2.2.1, guards.2.2.2.2.2.2⟩
    · exact ⟨hp, hv⟩
  | accept t e =>
    simp only [step, accept]
    split
    · exact ⟨Nat.le_refl 1, hv⟩
    · exact ⟨hp, hv⟩

/-- Clock advance commutes with acceptance: no newly imposed deadline can confiscate
    an admitted candidate's reward eligibility. -/
theorem acceptance_independent_of_clock (cfg : Config) (s : State) (d : Nat)
    (t : Bool) (e : Candidate) :
    accept cfg (tick s d) t e = tick (accept cfg s t e) d := by
  by_cases hr : s.phase = .rejected
  · simp [tick, accept, hr]
  · simp only [tick, hr, ite_false]
    unfold accept
    split <;> simp

/-- A valid timely submission remains accepted after arbitrary delay. -/
theorem submitted_can_accept_after_delay (cfg : Config) (s : State)
    (w g artifact d : Nat) (b : Binding)
    (hl : s.phase = .leased) (ho : w = s.owner) (hg : g = s.generation)
    (ht : s.now < s.expires) (hb : b = cfg.expected) (hn : s.candidate = none)
    (hw : participant cfg w) (hp : s.payouts = 0) (he : cfg.reward ≤ s.escrow) :
    (accept cfg (tick (submit cfg s w g b artifact) d) true
      { worker := w, generation := g, binding := b, artifact := artifact,
        submittedAt := s.now, leaseExpires := s.expires }).phase = .accepted := by
  subst w
  subst g
  subst b
  simp [submit, accept, tick, hl, ht, hn, hw, hp, he]

inductive Reachable (cfg : Config) (funder balanceA balanceB : Nat) : State → Prop
  | initial : Reachable cfg funder balanceA balanceB (initial cfg funder balanceA balanceB)
  | next {s : State} (h : Reachable cfg funder balanceA balanceB s) (a : Action) :
      Reachable cfg funder balanceA balanceB (step cfg s a)

theorem reachable_safe (cfg : Config) (funder a b : Nat) (s : State)
    (hr : Reachable cfg funder a b s) : safe cfg s := by
  induction hr with
  | initial => simp [safe, admittedValid, initial]
  | next hr action ih => exact step_preserves_safe cfg _ action ih

theorem reachable_conservation (cfg : Config) (funder a b : Nat) (s : State)
    (hr : Reachable cfg funder a b s) : total s = funder + cfg.reward + a + b := by
  induction hr with
  | initial => rfl
  | next hr action ih => rw [step_preserves_total, ih]

theorem at_most_one_payout (cfg : Config) (funder a b : Nat) (s : State)
    (hr : Reachable cfg funder a b s) : s.payouts ≤ 1 :=
  (reachable_safe cfg funder a b s hr).1

end ResearchExchange.Reward
