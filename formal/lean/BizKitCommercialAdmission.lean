import Init

/-!
# Protected commercial proposal admission

Universal conditional invariants over arbitrary finite source lists. This is
an ideal serialized admission kernel, not a proof that the Elixir appender,
cryptography, database, distributed recovery, or corporate authority implements
the kernel. Natural numbers stand for uninterpreted IDs and digest values;
collision resistance and authenticated provenance are external obligations.

The authoritative state supplies current source records, the complete sorted
pair source list, current member-key revisions and the active governance
declaration identity. `signaturesVerified` is the trusted signature verifier's
result, never an accepted request field. Governance permission here authorizes
only an inert proposal and exclusive business-log reservation. It is neither
corporate agency nor contractually effective discharge.

Historic proposal replay folds accepted records without consulting present
authority. New operations use the version/profile gate. Reservations are keyed
by chapter and ORIGINAL obligation ID, never by revision or amount. No release
or discharge transition is introduced by this model.
-/

namespace BizKitCommercialAdmission

structure SourceKey where
  chapter : Nat
  obligation : Nat
  deriving DecidableEq, Repr

structure IntentKey where
  chapter : Nat
  intent : Nat
  deriving DecidableEq, Repr

structure Scope where
  chapter : Nat
  partyA : Nat
  partyB : Nat
  currency : Nat
  deriving DecidableEq, Repr

inductive Profile where
  | legacy
  | protectedV2
  | unsupported (version : Nat)
  deriving DecidableEq, Repr

structure ProfileRef where
  eventId : Nat
  eventHash : Nat
  deriving DecidableEq, Repr

inductive Operation where
  | legacyNetting
  | legacyDischarge
  | legacyAssignment
  | legacyIntent
  | reservedProposalV2
  deriving DecidableEq, Repr

def profileAllows : Profile → Operation → Bool
  | .legacy, .reservedProposalV2 => false
  | .legacy, _ => true
  | .protectedV2, .reservedProposalV2 => true
  | .protectedV2, _ => false
  | .unsupported _, _ => false

structure SourceRef where
  key : SourceKey
  originalEventId : Nat
  originalEventHash : Nat
  revision : Nat
  latestEventId : Nat
  latestEventHash : Nat
  debtor : Nat
  creditor : Nat
  currency : Nat
  amount : Nat
  deriving DecidableEq, Repr

structure AuthorityRef where
  governanceKey : Nat
  declarationEventId : Nat
  declarationEventHash : Nat
  partyAKeyRevision : Nat
  partyBKeyRevision : Nat
  deriving DecidableEq, Repr

structure Proposal where
  scope : Scope
  intent : Nat
  version : Nat
  profileRef : ProfileRef
  authority : AuthorityRef
  sources : List SourceRef
  deriving DecidableEq, Repr

def Proposal.keys (p : Proposal) : List SourceKey := p.sources.map (·.key)
def Proposal.intentKey (p : Proposal) : IntentKey := ⟨p.scope.chapter, p.intent⟩

structure Book where
  owner : SourceKey → Option IntentKey
  seen : IntentKey → Bool
  count : Nat

def emptyBook : Book := ⟨fun _ => none, fun _ => false, 0⟩

structure State where
  profile : Nat → Profile
  profileRef : Nat → ProfileRef
  source : SourceKey → Option SourceRef
  sourceOpen : SourceKey → Bool
  originalOnly : SourceKey → Bool
  pairKeys : Scope → List SourceKey
  authority : Scope → AuthorityRef
  authorityActive : Scope → Bool
  book : Book

def SourceReady (s : State) (p : Proposal) (r : SourceRef) : Prop :=
  r.key.chapter = p.scope.chapter ∧
  s.source r.key = some r ∧
  s.sourceOpen r.key = true ∧
  s.originalOnly r.key = true ∧
  r.currency = p.scope.currency ∧
  0 < r.amount ∧
  ((r.debtor = p.scope.partyA ∧ r.creditor = p.scope.partyB) ∨
   (r.debtor = p.scope.partyB ∧ r.creditor = p.scope.partyA))

instance (s : State) (p : Proposal) (r : SourceRef) : Decidable (SourceReady s p r) := by
  unfold SourceReady
  infer_instance

structure Ready (s : State) (p : Proposal) (signaturesVerified : Bool) : Prop where
  protectedProfile : s.profile p.scope.chapter = .protectedV2
  exactVersion : p.version = 2
  exactProfileRef : p.profileRef = s.profileRef p.scope.chapter
  signatures : signaturesVerified = true
  activeAuthority : s.authorityActive p.scope = true
  exactAuthority : p.authority = s.authority p.scope
  freshIntent : s.book.seen p.intentKey = false
  completeKeys : p.keys = s.pairKeys p.scope
  distinctKeys : p.keys.Nodup
  atLeastTwo : 2 ≤ p.sources.length
  distinctParties : p.scope.partyA < p.scope.partyB
  currentSources : ∀ r ∈ p.sources, SourceReady s p r
  unreserved : ∀ key ∈ p.keys, s.book.owner key = none

theorem ready_iff (s : State) (p : Proposal) (ok : Bool) :
    Ready s p ok ↔
      s.profile p.scope.chapter = .protectedV2 ∧ p.version = 2 ∧ ok = true ∧
      p.profileRef = s.profileRef p.scope.chapter ∧
      s.authorityActive p.scope = true ∧ p.authority = s.authority p.scope ∧
      s.book.seen p.intentKey = false ∧ p.keys = s.pairKeys p.scope ∧
      p.keys.Nodup ∧ 2 ≤ p.sources.length ∧ p.scope.partyA < p.scope.partyB ∧
      (∀ r ∈ p.sources, SourceReady s p r) ∧
      (∀ key ∈ p.keys, s.book.owner key = none) := by
  constructor
  · intro h
    exact ⟨h.protectedProfile, h.exactVersion, h.signatures, h.exactProfileRef, h.activeAuthority,
      h.exactAuthority, h.freshIntent, h.completeKeys, h.distinctKeys,
      h.atLeastTwo, h.distinctParties, h.currentSources, h.unreserved⟩
  · rintro ⟨hp, hv, hs, href, ha, he, hf, hc, hd, hl, hparty, hsrc, hu⟩
    exact ⟨hp, hv, href, hs, ha, he, hf, hc, hd, hl, hparty, hsrc, hu⟩

instance (s : State) (p : Proposal) (ok : Bool) : Decidable (Ready s p ok) :=
  decidable_of_iff _ (ready_iff s p ok).symm

/-- Pure fold of an already accepted proposal. This is also the recovery fold. -/
def reserve (b : Book) (p : Proposal) : Book :=
  { owner := fun key => if key ∈ p.keys then some p.intentKey else b.owner key
    seen := fun key => if key = p.intentKey then true else b.seen key
    count := b.count + 1 }

/-- Ideal atomic, pre-persistence validation plus a single inert reservation. -/
def appendProposal (s : State) (p : Proposal) (signaturesVerified : Bool) : State :=
  if Ready s p signaturesVerified then { s with book := reserve s.book p } else s

/-- Monotonic activation. `currentGovernance` is the trusted conjunction of
valid signature, currently declared key, and exact equality of the signed
governance declaration event ID/hash to the active declaration at this same
serialized gate. It is not merely key equality: revoke/redeclare of the same
key must not resurrect an old activation. It is never a request boolean.
Unsupported version values never activate. -/
def activate (s : State) (chapter version : Nat) (ref : ProfileRef)
    (currentGovernance : Bool) : State :=
  if currentGovernance = true ∧ version = 2 ∧ s.profile chapter = .legacy then
    { s with
      profile := fun ch => if ch = chapter then .protectedV2 else s.profile ch
      profileRef := fun ch => if ch = chapter then ref else s.profileRef ch }
  else s

theorem protected_blocks_legacy_netting :
    profileAllows .protectedV2 .legacyNetting = false := rfl

theorem protected_blocks_legacy_discharge :
    profileAllows .protectedV2 .legacyDischarge = false := rfl

theorem protected_blocks_legacy_assignment :
    profileAllows .protectedV2 .legacyAssignment = false := rfl

theorem protected_blocks_legacy_intent :
    profileAllows .protectedV2 .legacyIntent = false := rfl

theorem unsupported_profile_fails_closed (version : Nat) (op : Operation) :
    profileAllows (.unsupported version) op = false := rfl

theorem activation_requires_current_governance (s : State) (chapter version : Nat)
    (ref : ProfileRef) :
    activate s chapter version ref false = s := by simp [activate]

theorem activation_rejects_unknown_version (s : State) (chapter version : Nat)
    (ref : ProfileRef) (current : Bool) (h : version ≠ 2) :
    activate s chapter version ref current = s := by simp [activate, h]

theorem activation_is_monotonic (s : State) (chapter version : Nat) (ref : ProfileRef) (current : Bool)
    (h : s.profile chapter = .protectedV2) :
    activate s chapter version ref current = s := by simp [activate, h]

theorem activation_protects (s : State) (chapter : Nat) (ref : ProfileRef)
    (h : s.profile chapter = .legacy) :
    (activate s chapter 2 ref true).profile chapter = .protectedV2 := by simp [activate, h]

theorem activation_does_not_change_other_chapter (s : State) (chapter other version : Nat)
    (ref : ProfileRef) (current : Bool) (h : other ≠ chapter) :
    (activate s chapter version ref current).profile other = s.profile other := by
  unfold activate
  split <;> simp_all

theorem refused_stutters (s : State) (p : Proposal) (ok : Bool)
    (h : ¬ Ready s p ok) : appendProposal s p ok = s := by simp [appendProposal, h]

theorem changed_state_requires_ready (s : State) (p : Proposal) (ok : Bool)
    (h : appendProposal s p ok ≠ s) : Ready s p ok := by
  unfold appendProposal at h
  split at h
  · assumption
  · exact False.elim (h rfl)

theorem unknown_version_refused (s : State) (p : Proposal) (ok : Bool)
    (h : p.version ≠ 2) : appendProposal s p ok = s := by
  apply refused_stutters
  intro hr
  exact h hr.exactVersion

theorem unsupported_profile_refused (s : State) (p : Proposal) (ok : Bool)
    (h : s.profile p.scope.chapter ≠ .protectedV2) : appendProposal s p ok = s := by
  apply refused_stutters
  intro hr
  exact h hr.protectedProfile

theorem mismatched_profile_event_refused (s : State) (p : Proposal) (ok : Bool)
    (h : p.profileRef ≠ s.profileRef p.scope.chapter) : appendProposal s p ok = s := by
  apply refused_stutters
  intro hr
  exact h hr.exactProfileRef

theorem changed_profile_event_hash_refused (s : State) (p : Proposal) (ok : Bool)
    (h : p.profileRef.eventHash ≠ (s.profileRef p.scope.chapter).eventHash) :
    appendProposal s p ok = s := by
  apply mismatched_profile_event_refused
  intro he
  exact h (congrArg ProfileRef.eventHash he)

theorem unchecked_signatures_refused (s : State) (p : Proposal) :
    appendProposal s p false = s := by
  apply refused_stutters
  intro hr
  cases hr.signatures

theorem revoked_authority_refused (s : State) (p : Proposal) (ok : Bool)
    (h : s.authorityActive p.scope = false) : appendProposal s p ok = s := by
  apply refused_stutters
  intro hr
  have ha := hr.activeAuthority
  rw [h] at ha
  cases ha

theorem stale_authority_refused (s : State) (p : Proposal) (ok : Bool)
    (h : p.authority ≠ s.authority p.scope) : appendProposal s p ok = s := by
  apply refused_stutters
  intro hr
  exact h hr.exactAuthority

theorem changed_governance_declaration_refused (s : State) (p : Proposal) (ok : Bool)
    (h : p.authority.declarationEventId ≠ (s.authority p.scope).declarationEventId) :
    appendProposal s p ok = s := by
  apply stale_authority_refused
  intro he
  exact h (congrArg AuthorityRef.declarationEventId he)

theorem changed_member_key_revision_refused (s : State) (p : Proposal) (ok : Bool)
    (h : p.authority.partyAKeyRevision ≠ (s.authority p.scope).partyAKeyRevision) :
    appendProposal s p ok = s := by
  apply stale_authority_refused
  intro he
  exact h (congrArg AuthorityRef.partyAKeyRevision he)

/-- Amounts are absent from this premise: identical totals cannot defeat a
changed complete original-identity list. -/
theorem substituted_keys_refused (s : State) (p : Proposal) (ok : Bool)
    (h : p.keys ≠ s.pairKeys p.scope) : appendProposal s p ok = s := by
  apply refused_stutters
  intro hr
  exact h hr.completeKeys

theorem mismatched_current_source_refused (s : State) (p : Proposal) (ok : Bool)
    (r : SourceRef) (hr : r ∈ p.sources) (h : s.source r.key ≠ some r) :
    appendProposal s p ok = s := by
  apply refused_stutters
  intro ready
  exact h (ready.currentSources r hr).2.1

theorem changed_revision_refused (s : State) (p : Proposal) (ok : Bool)
    (r actual : SourceRef) (hr : r ∈ p.sources)
    (hs : s.source r.key = some actual) (h : r.revision ≠ actual.revision) :
    appendProposal s p ok = s := by
  apply mismatched_current_source_refused s p ok r hr
  intro he
  have e : actual = r := Option.some.inj (hs.symm.trans he)
  exact h (congrArg SourceRef.revision e.symm)

theorem changed_original_event_hash_refused (s : State) (p : Proposal) (ok : Bool)
    (r actual : SourceRef) (hr : r ∈ p.sources)
    (hs : s.source r.key = some actual)
    (h : r.originalEventHash ≠ actual.originalEventHash) :
    appendProposal s p ok = s := by
  apply mismatched_current_source_refused s p ok r hr
  intro he
  have e : actual = r := Option.some.inj (hs.symm.trans he)
  exact h (congrArg SourceRef.originalEventHash e.symm)

theorem changed_original_event_id_refused (s : State) (p : Proposal) (ok : Bool)
    (r actual : SourceRef) (hr : r ∈ p.sources)
    (hs : s.source r.key = some actual)
    (h : r.originalEventId ≠ actual.originalEventId) :
    appendProposal s p ok = s := by
  apply mismatched_current_source_refused s p ok r hr
  intro he
  have e : actual = r := Option.some.inj (hs.symm.trans he)
  exact h (congrArg SourceRef.originalEventId e.symm)

theorem changed_latest_event_id_refused (s : State) (p : Proposal) (ok : Bool)
    (r actual : SourceRef) (hr : r ∈ p.sources)
    (hs : s.source r.key = some actual)
    (h : r.latestEventId ≠ actual.latestEventId) :
    appendProposal s p ok = s := by
  apply mismatched_current_source_refused s p ok r hr
  intro he
  have e : actual = r := Option.some.inj (hs.symm.trans he)
  exact h (congrArg SourceRef.latestEventId e.symm)

theorem changed_latest_event_hash_refused (s : State) (p : Proposal) (ok : Bool)
    (r actual : SourceRef) (hr : r ∈ p.sources)
    (hs : s.source r.key = some actual)
    (h : r.latestEventHash ≠ actual.latestEventHash) :
    appendProposal s p ok = s := by
  apply mismatched_current_source_refused s p ok r hr
  intro he
  have e : actual = r := Option.some.inj (hs.symm.trans he)
  exact h (congrArg SourceRef.latestEventHash e.symm)

theorem assigned_lineage_refused (s : State) (p : Proposal) (ok : Bool)
    (r : SourceRef) (hr : r ∈ p.sources) (h : s.originalOnly r.key = false) :
    appendProposal s p ok = s := by
  apply refused_stutters
  intro ready
  have ho := (ready.currentSources r hr).2.2.2.1
  rw [h] at ho
  contradiction

theorem closed_source_refused (s : State) (p : Proposal) (ok : Bool)
    (r : SourceRef) (hr : r ∈ p.sources) (h : s.sourceOpen r.key = false) :
    appendProposal s p ok = s := by
  apply refused_stutters
  intro ready
  have ho := (ready.currentSources r hr).2.2.1
  rw [h] at ho
  contradiction

theorem accepted_reserves_exact_sources (s : State) (p : Proposal) (ok : Bool)
    (h : Ready s p ok) (key : SourceKey) (hk : key ∈ p.keys) :
    (appendProposal s p ok).book.owner key = some p.intentKey := by
  simp [appendProposal, h, reserve, hk]

theorem accepted_preserves_unlisted_sources (s : State) (p : Proposal) (ok : Bool)
    (h : Ready s p ok) (key : SourceKey) (hk : key ∉ p.keys) :
    (appendProposal s p ok).book.owner key = s.book.owner key := by
  simp [appendProposal, h, reserve, hk]

theorem accepted_records_intent_once (s : State) (p : Proposal) (ok : Bool)
    (h : Ready s p ok) :
    (appendProposal s p ok).book.seen p.intentKey = true ∧
    (appendProposal s p ok).book.count = s.book.count + 1 := by
  simp [appendProposal, h, reserve]

theorem reserved_source_refused (s : State) (p : Proposal) (ok : Bool)
    (key : SourceKey) (hk : key ∈ p.keys) (h : s.book.owner key ≠ none) :
    appendProposal s p ok = s := by
  apply refused_stutters
  intro ready
  exact h (ready.unreserved key hk)

theorem seen_intent_refused (s : State) (p : Proposal) (ok : Bool)
    (h : s.book.seen p.intentKey = true) : appendProposal s p ok = s := by
  apply refused_stutters
  intro ready
  have hf := ready.freshIntent
  rw [h] at hf
  contradiction

theorem exact_retry_has_no_second_effect (s : State) (p : Proposal) (firstOK nextOK : Bool)
    (h : Ready s p firstOK) :
    appendProposal (appendProposal s p firstOK) p nextOK = appendProposal s p firstOK := by
  apply seen_intent_refused
  exact (accepted_records_intent_once s p firstOK h).1

/-- Any serial ordering admits at most one proposal sharing an original key,
even if the second request changes its revision, hashes, or intent. -/
theorem competing_proposal_refused (s : State) (first next : Proposal)
    (firstOK nextOK : Bool) (h : Ready s first firstOK)
    (key : SourceKey) (hfirst : key ∈ first.keys) (hnext : key ∈ next.keys) :
    appendProposal (appendProposal s first firstOK) next nextOK =
      appendProposal s first firstOK := by
  apply reserved_source_refused _ next nextOK key hnext
  rw [accepted_reserves_exact_sources s first firstOK h key hfirst]
  exact Option.some_ne_none _

theorem proposal_never_discharges (s : State) (p : Proposal) (ok : Bool) :
    (appendProposal s p ok).sourceOpen = s.sourceOpen := by
  unfold appendProposal
  split <;> rfl

theorem proposal_never_rewrites_sources (s : State) (p : Proposal) (ok : Bool) :
    (appendProposal s p ok).source = s.source := by
  unfold appendProposal
  split <;> rfl

theorem proposal_never_changes_profile (s : State) (p : Proposal) (ok : Bool) :
    (appendProposal s p ok).profile = s.profile := by
  unfold appendProposal
  split <;> rfl

theorem source_revision_is_not_reservation_identity (r : SourceRef) (revision : Nat) :
    ({ r with revision := revision } : SourceRef).key = r.key := rfl

theorem chapter_is_part_of_reservation_identity (chapter other obligation : Nat)
    (h : chapter ≠ other) :
    (⟨chapter, obligation⟩ : SourceKey) ≠ ⟨other, obligation⟩ := by
  intro he
  exact h (congrArg SourceKey.chapter he)

/-- Rebuild ONLY the reservation view from the canonical accepted proposal
subsequence. The full ledger's source/profile/authority folds are separately
required. This function deliberately has no current-authority argument. -/
def replayBook (history : List Proposal) : Book := history.foldl reserve emptyBook

theorem replay_append_agrees_with_record_fold (history : List Proposal) (p : Proposal) :
    replayBook (history ++ [p]) = reserve (replayBook history) p := by
  simp [replayBook, List.foldl_append]

theorem accepted_append_reconstructs_after_restart (s : State) (p : Proposal) (ok : Bool)
    (history : List Proposal) (hready : Ready s p ok) (hbook : s.book = replayBook history) :
    (appendProposal s p ok).book = replayBook (history ++ [p]) := by
  simp [appendProposal, hready, hbook, replay_append_agrees_with_record_fold]

theorem replay_of_prior_proposal_survives_current_revocation (s : State)
    (history : List Proposal) (hbook : s.book = replayBook history) :
    ({ s with authorityActive := fun _ => false } : State).book = replayBook history := hbook

theorem reserve_preserves_existing_reservation (b : Book) (p : Proposal) (key : SourceKey)
    (h : b.owner key ≠ none) : (reserve b p).owner key ≠ none := by
  simp only [reserve]
  split
  · exact Option.some_ne_none _
  · exact h

theorem replay_suffix_preserves_existing_reservation (b : Book) (suffix : List Proposal)
    (key : SourceKey) (h : b.owner key ≠ none) :
    (suffix.foldl reserve b).owner key ≠ none := by
  induction suffix generalizing b with
  | nil => exact h
  | cons p rest ih =>
    exact ih (reserve b p) (reserve_preserves_existing_reservation b p key h)

theorem recorded_source_stays_reserved_after_restart (prior suffix : List Proposal)
    (p : Proposal) (key : SourceKey) (hk : key ∈ p.keys) :
    (replayBook (prior ++ p :: suffix)).owner key ≠ none := by
  simp only [replayBook, List.foldl_append, List.foldl_cons]
  apply replay_suffix_preserves_existing_reservation
  simp [reserve, hk]

/-- Historical legacy close semantics remain independent of the NEW gate. -/
def replayLegacyClose (s : State) (keys : List SourceKey) : State :=
  { s with sourceOpen := fun key => if key ∈ keys then false else s.sourceOpen key }

def appendLegacyClose (s : State) (chapter : Nat) (keys : List SourceKey) : State :=
  if profileAllows (s.profile chapter) .legacyDischarge then replayLegacyClose s keys else s

theorem protected_new_legacy_close_is_refused (s : State) (chapter : Nat)
    (keys : List SourceKey) (h : s.profile chapter = .protectedV2) :
    appendLegacyClose s chapter keys = s := by simp [appendLegacyClose, h, profileAllows]

theorem historical_legacy_close_still_replays (s : State) (keys : List SourceKey)
    (key : SourceKey) (h : key ∈ keys) :
    (replayLegacyClose s keys).sourceOpen key = false := by simp [replayLegacyClose, h]

/-! Concrete nonvacuity witnesses, also used by the false-theorem controls. -/

def exampleScope : Scope := ⟨1, 1, 2, 1⟩
def exampleProfileRef : ProfileRef := ⟨12, 112⟩
def exampleAuthority : AuthorityRef := ⟨7, 11, 111, 0, 0⟩
def exampleFirst : SourceRef := ⟨⟨1, 1⟩, 21, 121, 0, 21, 121, 1, 2, 1, 100⟩
def exampleSecond : SourceRef := ⟨⟨1, 2⟩, 22, 122, 0, 22, 122, 2, 1, 1, 60⟩
def exampleProposal : Proposal :=
  ⟨exampleScope, 31, 2, exampleProfileRef, exampleAuthority, [exampleFirst, exampleSecond]⟩

def exampleState : State :=
  { profile := fun _ => .protectedV2
    profileRef := fun _ => exampleProfileRef
    source := fun key => if key = exampleFirst.key then some exampleFirst
      else if key = exampleSecond.key then some exampleSecond else none
    sourceOpen := fun _ => true
    originalOnly := fun _ => true
    pairKeys := fun _ => exampleProposal.keys
    authority := fun _ => exampleAuthority
    authorityActive := fun _ => true
    book := emptyBook }

theorem nonvacuous_ready : Ready exampleState exampleProposal true := by decide

theorem nonvacuous_acceptance :
    (appendProposal exampleState exampleProposal true).book.count = 1 := by decide

theorem nonvacuous_conflict_refusal :
    (appendProposal (appendProposal exampleState exampleProposal true)
      { exampleProposal with intent := 32 } true).book.count = 1 := by decide

theorem nonvacuous_revocation_refusal :
    (appendProposal { exampleState with authorityActive := fun _ => false }
      exampleProposal true).book.count = 0 := by decide

theorem nonvacuous_revision_refusal :
    (appendProposal exampleState
      { exampleProposal with sources :=
          [{ exampleFirst with revision := 1 }, exampleSecond] } true).book.count = 0 := by decide

theorem nonvacuous_restart_reservation :
    (replayBook [exampleProposal]).owner exampleFirst.key = some exampleProposal.intentKey := by
  decide

end BizKitCommercialAdmission
