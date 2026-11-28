import Std

/- Pure model of ResearchCore.Access at biz-kit 961cfd7b9dd38fab2a6b9c43260ead81ba62a501.
   Valid records and well-typed material/audience/action values only.
   A proposed actor is NOT an authenticated signer; no host effect is modeled. -/
namespace BizKitResearchConsent

structure Scope where
  chapter : String
  tenant : String
  project : String
  deriving DecidableEq, Repr

inductive Actor where
  | narrator (id : String)
  | community (id : String)
  | sponsor (id : String)
  | operator (id : String)
  | governance (id : String)
  deriving DecidableEq, Repr

inductive Material where
  | audio | transcript | excerpt
  deriving DecidableEq, Repr

inductive Audience where
  | research | publicAudience
  deriving DecidableEq, Repr

structure Pair where
  material : Material
  audience : Audience
  deriving DecidableEq, Repr

structure Key where
  actor : Actor
  pair : Pair
  deriving DecidableEq, Repr

inductive Action where
  | grant | revoke
  deriving DecidableEq, Repr

def Action.value : Action → Bool
  | .grant => true
  | .revoke => false

structure Record where
  scope : Scope
  recordId : String
  narrators : List String
  community : String
  grants : Key → Bool
  revision : Nat

def reviewers (r : Record) : List Actor :=
  .community r.community :: r.narrators.map Actor.narrator

def newRecord (s : Scope) (id : String) (ns : List String) (c : String) : Record :=
  ⟨s, id, ns, c, fun _ => false, 0⟩

def eligible (r : Record) (s : Scope) (p : Pair) : Prop :=
  s = r.scope ∧ ∀ a ∈ reviewers r, r.grants ⟨a, p⟩ = true

def eligibleBool (r : Record) (s : Scope) (p : Pair) : Bool :=
  decide (s = r.scope) && (reviewers r).all (fun a => r.grants ⟨a, p⟩)

private theorem all_iff (xs : List Actor) (f : Actor → Bool) :
    xs.all f = true ↔ ∀ a ∈ xs, f a = true := by
  induction xs with
  | nil => simp
  | cons x xs ih =>
    simp only [List.all_cons, Bool.and_eq_true, ih, List.mem_cons]
    constructor
    · rintro ⟨hx, ht⟩ a (ha | ha)
      · subst a
        exact hx
      · exact ht a ha
    · intro h
      exact ⟨h x (Or.inl rfl), fun a ha => h a (Or.inr ha)⟩

theorem eligibleBool_iff (r : Record) (s : Scope) (p : Pair) :
    eligibleBool r s p = true ↔ eligible r s p := by
  simp [eligibleBool, eligible, all_iff]

inductive Error where
  | scopeMismatch | staleRevision | unauthorized | unchanged
  deriving DecidableEq, Repr

structure Command where
  scope : Scope
  actor : Actor
  action : Action
  pair : Pair
  expectedRevision : Nat
  deriving DecidableEq, Repr

def Command.key (c : Command) : Key := ⟨c.actor, c.pair⟩

def update (r : Record) (c : Command) : Record :=
  { r with
    grants := fun k => if k = c.key then c.action.value else r.grants k
    revision := r.revision + 1 }

-- Guard order is the Elixir order restricted to well-typed commands.
def review (r : Record) (c : Command) : Except Error Record :=
  if c.scope ≠ r.scope then .error .scopeMismatch
  else if c.expectedRevision ≠ r.revision then .error .staleRevision
  else if c.actor ∉ reviewers r then .error .unauthorized
  else if r.grants c.key = c.action.value then .error .unchanged
  else .ok (update r c)

def admissible (r : Record) (c : Command) : Prop :=
  c.scope = r.scope ∧ c.expectedRevision = r.revision ∧
  c.actor ∈ reviewers r ∧ r.grants c.key ≠ c.action.value

theorem review_success_iff (r r' : Record) (c : Command) :
    review r c = .ok r' ↔ admissible r c ∧ r' = update r c := by
  by_cases hs : c.scope = r.scope <;>
    by_cases hv : c.expectedRevision = r.revision <;>
    by_cases ha : c.actor ∈ reviewers r <;>
    by_cases hg : r.grants c.key = c.action.value <;>
    simp [review, admissible, hs, hv, ha, hg] <;> exact eq_comm

theorem wrong_scope_refused (r : Record) (c : Command)
    (h : c.scope ≠ r.scope) : review r c = .error .scopeMismatch := by
  simp [review, h]

theorem stale_refused (r : Record) (c : Command)
    (hs : c.scope = r.scope) (hv : c.expectedRevision ≠ r.revision) :
    review r c = .error .staleRevision := by
  simp [review, hs, hv]

theorem unauthorized_refused (r : Record) (c : Command)
    (hs : c.scope = r.scope) (hv : c.expectedRevision = r.revision)
    (ha : c.actor ∉ reviewers r) : review r c = .error .unauthorized := by
  simp [review, hs, hv, ha]

theorem unchanged_refused (r : Record) (c : Command)
    (hs : c.scope = r.scope) (hv : c.expectedRevision = r.revision)
    (ha : c.actor ∈ reviewers r) (hg : r.grants c.key = c.action.value) :
    review r c = .error .unchanged := by
  simp [review, hs, hv, ha, hg]

theorem initial_denied (s : Scope) (id : String) (ns : List String)
    (community : String) (p : Pair) (queryScope : Scope) :
    ¬ eligible (newRecord s id ns community) queryScope p := by
  intro h
  have hc := h.2 (.community community) (by simp [reviewers, newRecord])
  simp [newRecord] at hc

theorem eligible_requires_community (r : Record) (s : Scope) (p : Pair)
    (h : eligible r s p) : r.grants ⟨.community r.community, p⟩ = true :=
  h.2 _ (by simp [reviewers])

theorem eligible_requires_narrator (r : Record) (s : Scope) (p : Pair)
    (n : String) (hn : n ∈ r.narrators) (h : eligible r s p) :
    r.grants ⟨.narrator n, p⟩ = true :=
  h.2 _ (by simp [reviewers, List.mem_map, hn])

theorem eligible_wrong_scope (r : Record) (s : Scope) (p : Pair)
    (h : s ≠ r.scope) : ¬ eligible r s p := fun e => h e.1

theorem sponsor_not_reviewer (r : Record) (id : String) :
    Actor.sponsor id ∉ reviewers r := by
  simp [reviewers, List.mem_map]

theorem operator_not_reviewer (r : Record) (id : String) :
    Actor.operator id ∉ reviewers r := by
  simp [reviewers, List.mem_map]

theorem governance_not_reviewer (r : Record) (id : String) :
    Actor.governance id ∉ reviewers r := by
  simp [reviewers, List.mem_map]

theorem accepted_metadata (r r' : Record) (c : Command)
    (h : review r c = .ok r') :
    r'.scope = r.scope ∧ r'.recordId = r.recordId ∧
    r'.narrators = r.narrators ∧ r'.community = r.community ∧
    r'.revision = r.revision + 1 := by
  obtain ⟨_, hr⟩ := (review_success_iff r r' c).mp h
  subst r'
  exact ⟨rfl, rfl, rfl, rfl, rfl⟩

theorem accepted_key (r r' : Record) (c : Command)
    (h : review r c = .ok r') : r'.grants c.key = c.action.value := by
  obtain ⟨_, hr⟩ := (review_success_iff r r' c).mp h
  subst r'
  simp [update]

theorem accepted_other_key (r r' : Record) (c : Command) (k : Key)
    (h : review r c = .ok r') (hk : k ≠ c.key) :
    r'.grants k = r.grants k := by
  obtain ⟨_, hr⟩ := (review_success_iff r r' c).mp h
  subst r'
  simp [update, hk]

theorem other_pair_unchanged (r r' : Record) (c : Command) (s : Scope) (p : Pair)
    (h : review r c = .ok r') (hp : p ≠ c.pair) :
    eligible r' s p ↔ eligible r s p := by
  obtain ⟨_, hr⟩ := (review_success_iff r r' c).mp h
  subst r'
  have hkey (a : Actor) : (⟨a, p⟩ : Key) ≠ c.key := by
    intro he
    exact hp (congrArg Key.pair he)
  simp [eligible, reviewers, update, hkey]

theorem accepted_revoke_denies (r r' : Record) (c : Command)
    (h : review r c = .ok r') (ha : c.action = .revoke) (s : Scope) :
    ¬ eligible r' s c.pair := by
  obtain ⟨had, hr⟩ := (review_success_iff r r' c).mp h
  have hk := accepted_key r r' c h
  have hm : c.actor ∈ reviewers r' := by
    rw [hr]
    exact had.2.2.1
  intro e
  have ht := e.2 c.actor hm
  change r'.grants c.key = true at ht
  rw [hk, ha] at ht
  simp [Action.value] at ht

theorem accepted_command_cannot_replay (r r' : Record) (c : Command)
    (h : review r c = .ok r') : review r' c = .error .staleRevision := by
  obtain ⟨had, hr⟩ := (review_success_iff r r' c).mp h
  obtain ⟨hs, hv, _, _, hrev⟩ := accepted_metadata r r' c h
  apply stale_refused
  · exact had.1.trans hs.symm
  · rw [had.2.1, hrev]
    exact Nat.ne_of_lt (Nat.lt_succ_self _)

def replay (r : Record) : List Command → Except Error Record
  | [] => .ok r
  | c :: cs => match review r c with
    | .error e => .error e
    | .ok r' => replay r' cs

theorem replay_functional (r r₁ r₂ : Record) (cs : List Command)
    (h₁ : replay r cs = .ok r₁) (h₂ : replay r cs = .ok r₂) : r₁ = r₂ := by
  rw [h₁] at h₂
  exact Except.ok.inj h₂

end BizKitResearchConsent
