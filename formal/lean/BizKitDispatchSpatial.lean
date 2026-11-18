import Init

/-!
# Dispatch spatial reads and reconciliation

Opaque identifiers are represented by naturals, with separate types for record
references. `Scope` is the *identity tuple before hashing*: the runtime's scope
digest is an equality token, not authentication. Collision resistance, principal
resolution, consent queries, coordinate parsing, HTTP ordering, database reads,
timers and Cesium are runtime refinement obligations.

The client receives complete replacement frames. A new view starts with a GET,
then accepts exactly one handoff to a different SSE stream at sequence zero.
Within that stream, only increasing sequence numbers replace the view. Ignored
frames do not renew liveness. Clearing invalidates pending work, selection,
locations and watches. All transitions preserve the abstract business state.
-/

namespace BizKitDispatchSpatial

inductive PrincipalKind where
  | participant | service
  deriving DecidableEq, Repr

structure Scope where
  tenant : Nat
  organization : Nat
  principalKind : PrincipalKind
  principal : Nat
  role : Nat
  deriving DecidableEq, Repr

structure ParticipantRef where
  id : Nat
  deriving DecidableEq, Repr

structure ObservationRef where
  id : Nat
  deriving DecidableEq, Repr

structure Subject where
  participant : ParticipantRef
  observation : ObservationRef
  deriving DecidableEq, Repr

structure Authority where
  scope : Scope
  sessionCurrent : Bool
  roleCurrent : Bool
  participantRead : Bool
  preciseRead : Bool
  loadRead : Bool
  assignmentRead : Bool
  deriving DecidableEq, Repr

structure Sample where
  subject : Subject
  tenant : Nat
  organization : Nat
  assignment : Nat
  originalConsent : Nat
  deriving DecidableEq, Repr

structure Consent where
  id : Nat
  tenant : Nat
  participant : ParticipantRef
  assignment : Nat
  activeNow : Bool
  coversAcquisition : Bool
  deriving DecidableEq, Repr

abbrev authorized (expected : Scope) (a : Authority) : Prop :=
  a.scope = expected ∧ a.sessionCurrent = true ∧ a.roleCurrent = true ∧
  a.participantRead = true ∧ a.preciseRead = true

abbrev mayObserve (expected : Scope) (a : Authority) (s : Sample) (c : Consent) : Prop :=
  authorized expected a ∧ s.tenant = expected.tenant ∧
  s.organization = expected.organization ∧ c.tenant = expected.tenant ∧
  c.participant = s.subject.participant ∧ c.assignment = s.assignment ∧
  c.id = s.originalConsent ∧ c.activeNow = true ∧ c.coversAcquisition = true

def observe (expected : Scope) (a : Authority) (s : Sample) (c : Consent) : Option Subject :=
  if mayObserve expected a s c then some s.subject else none

theorem authorized_observation_is_shown (e : Scope) (a : Authority) (s : Sample) (c : Consent)
    (h : mayObserve e a s c) : observe e a s c = some s.subject := by
  simp [observe, h]

theorem refused_observation_is_absent (e : Scope) (a : Authority) (s : Sample) (c : Consent)
    (h : ¬ mayObserve e a s c) : observe e a s c = none := by
  simp [observe, h]

theorem foreign_organization_is_absent (e : Scope) (a : Authority) (s : Sample) (c : Consent)
    (h : s.organization ≠ e.organization) : observe e a s c = none := by
  apply refused_observation_is_absent
  intro accepted
  exact h accepted.2.2.1

theorem foreign_tenant_is_absent (e : Scope) (a : Authority) (s : Sample) (c : Consent)
    (h : s.tenant ≠ e.tenant) : observe e a s c = none := by
  apply refused_observation_is_absent
  intro accepted
  exact h accepted.2.1

theorem changed_selected_authority_is_absent (e : Scope) (a : Authority) (s : Sample) (c : Consent)
    (h : a.scope ≠ e) : observe e a s c = none := by
  apply refused_observation_is_absent
  intro accepted
  exact h accepted.1.1

theorem missing_precise_capability_is_absent (e : Scope) (a : Authority) (s : Sample) (c : Consent)
    (h : a.preciseRead = false) : observe e a s c = none := by
  apply refused_observation_is_absent
  intro accepted
  have present := accepted.1.2.2.2.2
  simp [h] at present

theorem replacement_consent_cannot_reveal_original (e : Scope) (a : Authority)
    (s : Sample) (c : Consent) (h : c.id ≠ s.originalConsent) : observe e a s c = none := by
  apply refused_observation_is_absent
  intro accepted
  exact h accepted.2.2.2.2.2.2.1

theorem inactive_consent_is_absent (e : Scope) (a : Authority) (s : Sample) (c : Consent)
    (h : c.activeNow = false) : observe e a s c = none := by
  apply refused_observation_is_absent
  intro accepted
  have present := accepted.2.2.2.2.2.2.2.1
  simp [h] at present

theorem acquisition_outside_consent_is_absent (e : Scope) (a : Authority)
    (s : Sample) (c : Consent) (h : c.coversAcquisition = false) : observe e a s c = none := by
  apply refused_observation_is_absent
  intro accepted
  have present := accepted.2.2.2.2.2.2.2.2
  simp [h] at present

inductive Phase where
  | snapshot | handoff | streaming | stopped
  deriving DecidableEq, Repr

inductive Transport where
  | get | stream
  deriving DecidableEq, Repr

inductive Decision where
  | ignore | clear | apply
  deriving DecidableEq, Repr

structure View where
  expected : Scope
  generation : Nat
  phase : Phase
  stream : Nat
  sequence : Nat
  visible : List Subject
  selected : Option Subject
  work : Option Subject
  workEpoch : Nat
  workAllowed : Bool
  liveness : Nat
  watching : Bool
  businessVersion : Nat
  deriving DecidableEq, Repr

structure Frame where
  scope : Scope
  generation : Nat
  transport : Transport
  stream : Nat
  sequence : Nat
  wellFormed : Bool
  visible : List Subject
  workAllowed : Bool
  deriving DecidableEq, Repr

/-- Refusal, disconnection and expiry use the same erasure transition. -/
def clear (s : View) : View :=
  { s with
    generation := s.generation + 1
    phase := .stopped
    visible := []
    selected := none
    work := none
    workEpoch := s.workEpoch + 1
    workAllowed := false
    watching := false }

/-- A freshly authorized reconnect still has no data until a new GET succeeds. -/
def reconnect (s : View) (scope : Scope) : View :=
  { clear s with expected := scope, phase := .snapshot }

def classify (s : View) (f : Frame) : Decision :=
  if s.phase = .stopped ∨ f.generation ≠ s.generation then .ignore
  else if f.scope ≠ s.expected ∨ f.wellFormed = false then .clear
  else match s.phase with
    | .snapshot =>
      if f.transport = .get ∧ f.sequence = 0 then .apply else .clear
    | .handoff =>
      if f.transport = .stream ∧ f.sequence = 0 ∧ f.stream ≠ s.stream then .apply else .clear
    | .streaming =>
      if f.transport ≠ .stream ∨ f.stream ≠ s.stream then .clear
      else if f.sequence ≤ s.sequence then .ignore else .apply
    | .stopped => .ignore

def retainedSelection (selected : Option Subject) (visible : List Subject) : Option Subject :=
  match selected with
  | none => none
  | some subject => if subject ∈ visible then some subject else none

def applyFrame (s : View) (f : Frame) : View :=
  { s with
    phase := if f.transport = .get then .handoff else .streaming
    stream := f.stream
    sequence := f.sequence
    visible := f.visible
    selected := retainedSelection s.selected f.visible
    work := none
    workEpoch := s.workEpoch + 1
    workAllowed := f.workAllowed
    liveness := s.liveness + 1
    watching := f.transport == .stream }

def receive (s : View) (f : Frame) : View :=
  match classify s f with
  | .ignore => s
  | .clear => clear s
  | .apply => applyFrame s f

theorem clear_erases_all_private_surfaces (s : View) :
    (clear s).visible = [] ∧ (clear s).selected = none ∧
    (clear s).work = none ∧ (clear s).watching = false := by
  simp [clear]

theorem clear_invalidates_pending_generation (s : View) :
    (clear s).generation = s.generation + 1 ∧
    (clear s).workEpoch = s.workEpoch + 1 := by
  simp [clear]

theorem reconnect_starts_empty (s : View) (scope : Scope) :
    (reconnect s scope).visible = [] ∧ (reconnect s scope).selected = none ∧
    (reconnect s scope).work = none ∧ (reconnect s scope).watching = false ∧
    (reconnect s scope).phase = .snapshot ∧ (reconnect s scope).expected = scope := by
  simp [reconnect, clear]

theorem old_generation_is_ignored (s : View) (f : Frame)
    (old : f.generation ≠ s.generation) : receive s f = s := by
  simp [receive, classify, old]

theorem stopped_view_cannot_be_restored (s : View) (f : Frame)
    (stopped : s.phase = .stopped) : receive s f = s := by
  simp [receive, classify, stopped]

theorem cleared_view_cannot_be_restored (s : View) (f : Frame) :
    receive (clear s) f = clear s := by
  exact stopped_view_cannot_be_restored (clear s) f rfl

theorem wrong_scope_clears (s : View) (f : Frame)
    (running : s.phase ≠ .stopped) (current : f.generation = s.generation)
    (foreign : f.scope ≠ s.expected) : receive s f = clear s := by
  simp [receive, classify, running, current, foreign]

theorem malformed_frame_clears (s : View) (f : Frame)
    (running : s.phase ≠ .stopped) (current : f.generation = s.generation)
    (malformed : f.wellFormed = false) : receive s f = clear s := by
  simp [receive, classify, running, current, malformed]

theorem wrong_stream_clears (s : View) (f : Frame)
    (streaming : s.phase = .streaming) (current : f.generation = s.generation)
    (scope : f.scope = s.expected) (valid : f.wellFormed = true)
    (foreign : f.stream ≠ s.stream) : receive s f = clear s := by
  simp [receive, classify, streaming, current, scope, valid, foreign]

theorem old_or_duplicate_cursor_is_ignored (s : View) (f : Frame)
    (streaming : s.phase = .streaming) (current : f.generation = s.generation)
    (scope : f.scope = s.expected) (valid : f.wellFormed = true)
    (transport : f.transport = .stream) (stream : f.stream = s.stream)
    (old : f.sequence ≤ s.sequence) : receive s f = s := by
  simp [receive, classify, streaming, current, scope, valid, transport, stream, old]

theorem ignored_frame_cannot_renew_liveness (s : View) (f : Frame)
    (ignored : classify s f = .ignore) : (receive s f).liveness = s.liveness := by
  simp [receive, ignored]

theorem snapshot_handoff_requires_zero (s : View) (f : Frame)
    (waiting : s.phase = .handoff) (current : f.generation = s.generation)
    (scope : f.scope = s.expected) (valid : f.wellFormed = true)
    (nonzero : f.sequence ≠ 0) : receive s f = clear s := by
  simp [receive, classify, waiting, current, scope, valid, nonzero]

theorem handoff_requires_new_stream (s : View) (f : Frame)
    (waiting : s.phase = .handoff) (current : f.generation = s.generation)
    (scope : f.scope = s.expected) (valid : f.wellFormed = true)
    (same : f.stream = s.stream) : receive s f = clear s := by
  simp [receive, classify, waiting, current, scope, valid, same]

theorem accepted_frame_is_complete_replacement (s : View) (f : Frame)
    (accepted : classify s f = .apply) : (receive s f).visible = f.visible := by
  simp [receive, accepted, applyFrame]

theorem removed_selection_is_erased (s : View) (f : Frame) (subject : Subject)
    (accepted : classify s f = .apply) (selected : s.selected = some subject)
    (absent : subject ∉ f.visible) : (receive s f).selected = none := by
  simp [receive, accepted, applyFrame, retainedSelection, selected, absent]

theorem replacement_requires_new_work_read (s : View) (f : Frame)
    (accepted : classify s f = .apply) :
    (receive s f).work = none ∧ (receive s f).workEpoch = s.workEpoch + 1 := by
  simp [receive, accepted, applyFrame]

theorem frame_processing_preserves_business (s : View) (f : Frame) :
    (receive s f).businessVersion = s.businessVersion := by
  unfold receive
  cases classify s f <;> rfl

def select (s : View) (subject : Subject) : View :=
  if s.phase ≠ .stopped ∧ subject ∈ s.visible then
    { s with selected := some subject, work := none, workEpoch := s.workEpoch + 1 }
  else s

structure WorkReply where
  scope : Scope
  generation : Nat
  requestEpoch : Nat
  subject : Subject
  loadRead : Bool
  assignmentRead : Bool
  deriving DecidableEq, Repr

abbrev mayShowWork (s : View) (reply : WorkReply) : Prop :=
  s.phase ≠ .stopped ∧ s.workAllowed = true ∧ reply.loadRead = true ∧
  reply.assignmentRead = true ∧ reply.scope = s.expected ∧
  reply.generation = s.generation ∧ reply.requestEpoch = s.workEpoch ∧
  s.selected = some reply.subject ∧ reply.subject ∈ s.visible

def receiveWork (s : View) (reply : WorkReply) : View :=
  if mayShowWork s reply then { s with work := some reply.subject } else s

theorem authorized_matching_work_is_shown (s : View) (reply : WorkReply)
    (h : mayShowWork s reply) : (receiveWork s reply).work = some reply.subject := by
  unfold receiveWork
  split
  · rfl
  · contradiction

theorem cleared_view_refuses_late_work (s : View) (reply : WorkReply) :
    receiveWork (clear s) reply = clear s := by
  simp [receiveWork, mayShowWork, clear]

theorem replaced_request_refuses_late_work (s : View) (reply : WorkReply)
    (old : reply.requestEpoch ≠ s.workEpoch) : receiveWork s reply = s := by
  have refused : ¬ mayShowWork s reply := by
    intro accepted
    exact old accepted.2.2.2.2.2.2.1
  simp [receiveWork, refused]

theorem changed_selection_refuses_work (s : View) (reply : WorkReply)
    (different : s.selected ≠ some reply.subject) : receiveWork s reply = s := by
  have refused : ¬ mayShowWork s reply := by
    intro accepted
    exact different accepted.2.2.2.2.2.2.2.1
  simp [receiveWork, refused]

theorem missing_work_capability_refuses_work (s : View) (reply : WorkReply)
    (missing : s.workAllowed = false) : receiveWork s reply = s := by
  have refused : ¬ mayShowWork s reply := by
    intro accepted
    have present := accepted.2.1
    simp [missing] at present
  simp [receiveWork, refused]

theorem missing_load_read_refuses_work (s : View) (reply : WorkReply)
    (missing : reply.loadRead = false) : receiveWork s reply = s := by
  have refused : ¬ mayShowWork s reply := by
    intro accepted
    have present := accepted.2.2.1
    simp [missing] at present
  simp [receiveWork, refused]

theorem missing_assignment_read_refuses_work (s : View) (reply : WorkReply)
    (missing : reply.assignmentRead = false) : receiveWork s reply = s := by
  have refused : ¬ mayShowWork s reply := by
    intro accepted
    have present := accepted.2.2.2.1
    simp [missing] at present
  simp [receiveWork, refused]

theorem changed_scope_refuses_work (s : View) (reply : WorkReply)
    (foreign : reply.scope ≠ s.expected) : receiveWork s reply = s := by
  have refused : ¬ mayShowWork s reply := by
    intro accepted
    exact foreign accepted.2.2.2.2.1
  simp [receiveWork, refused]

theorem old_generation_refuses_work (s : View) (reply : WorkReply)
    (old : reply.generation ≠ s.generation) : receiveWork s reply = s := by
  have refused : ¬ mayShowWork s reply := by
    intro accepted
    exact old accepted.2.2.2.2.2.1
  simp [receiveWork, refused]

theorem work_inspection_preserves_business (s : View) (reply : WorkReply) :
    (receiveWork s reply).businessVersion = s.businessVersion := by
  unfold receiveWork
  split <;> rfl

theorem selection_preserves_business (s : View) (subject : Subject) :
    (select s subject).businessVersion = s.businessVersion := by
  unfold select
  split <;> rfl

theorem reconnect_preserves_business (s : View) (scope : Scope) :
    (reconnect s scope).businessVersion = s.businessVersion := rfl

end BizKitDispatchSpatial
