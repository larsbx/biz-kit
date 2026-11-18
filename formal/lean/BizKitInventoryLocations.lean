import Lean

/-! I-2 restricted refinement target: two locations, one persistent reservation
ID at each location, exact naturals, explicit clock and complete command history.
Closed records retain remaining quantity. This is not an Elixir refinement proof.
The fixture executable below evaluates this same transition function. -/
namespace BizKitInventoryLocations

inductive Status where
  | active | committed | released | expired
  deriving Repr, DecidableEq, Inhabited

structure Reservation where
  remaining : Nat
  expires : Nat
  status : Status
  deriving Repr, DecidableEq, Inhabited

def held : Option Reservation → Nat
  | some r => if r.status = .active then r.remaining else 0
  | none => 0

structure Stock where
  onHand : Bool → Nat
  reservations : Bool → Option Reservation
  watermark : Nat

-- Bool is the exact finite location set {a,b}; reservation IDs are hold-a/hold-b.
def Safe (s : Stock) : Prop := ∀ l, held (s.reservations l) ≤ s.onHand l

def Positive (s : Stock) : Prop := ∀ l r,
  s.reservations l = some r → r.status = .active → 0 < r.remaining

def put (f : Bool → α) (l : Bool) (v : α) : Bool → α :=
  fun k => if k = l then v else f k

def updateSlot (s : Stock) (l : Bool) (n : Nat) (r : Option Reservation) : Stock :=
  { s with onHand := put s.onHand l n, reservations := put s.reservations l r }

theorem local_safe (s : Stock) (l : Bool) (n : Nat) (r : Option Reservation)
    (hs : Safe s) (h : held r ≤ n) : Safe (updateSlot s l n r) := by
  intro k
  by_cases hk : k = l
  · simpa [updateSlot, put, hk] using h
  · simpa [updateSlot, put, hk] using hs k

theorem local_positive (s : Stock) (l : Bool) (n : Nat) (r : Option Reservation)
    (hs : Positive s) (h : ∀ x, r = some x → x.status = .active → 0 < x.remaining) :
    Positive (updateSlot s l n r) := by
  intro k x hx ha
  by_cases hk : k = l
  · exact h x (by simpa [updateSlot, put, hk] using hx) ha
  · exact hs k x (by simpa [updateSlot, put, hk] using hx) ha

inductive Op where
  | receive | reserve | commit | release | transfer | expire
  deriving Repr, DecidableEq, Inhabited

structure Command where
  id : Nat
  version : Nat
  op : Op
  location : Bool
  quantity : Nat
  expires : Nat
  deriving Repr, DecidableEq, Inhabited

def transition (s : Stock) (c : Command) : Except String Stock :=
  let l := c.location
  let q := c.quantity
  match c.op with
  | .receive =>
    if q = 0 then .error "invalid_quantity" else
    .ok (updateSlot s l (s.onHand l + q) (s.reservations l))
  | .reserve =>
    if q = 0 then .error "invalid_quantity" else
    if c.expires ≤ s.watermark then .error "invalid_expiry" else
    if (s.reservations l).isSome then .error "reservation_exists" else
    if q > s.onHand l - held (s.reservations l) then .error "insufficient_available" else
    .ok (updateSlot s l (s.onHand l) (some ⟨q, c.expires, .active⟩))
  | .commit =>
    if q = 0 then .error "invalid_quantity" else
    match s.reservations l with
    | none => .error "unknown_reservation"
    | some r =>
      if r.status ≠ .active ∨ q > r.remaining then .error "reservation_not_active" else
      .ok (updateSlot s l (s.onHand l - q)
        (some { r with remaining := r.remaining - q, status := if r.remaining = q then .committed else .active }))
  | .release =>
    match s.reservations l with
    | none => .error "unknown_reservation"
    | some r =>
      if r.status ≠ .active then .error "reservation_not_active" else
      .ok (updateSlot s l (s.onHand l) (some { r with status := .released }))
  | .transfer =>
    if q = 0 then .error "invalid_quantity" else
    if q > s.onHand l - held (s.reservations l) then .error "insufficient_available" else
    .ok { s with onHand := put (put s.onHand l (s.onHand l - q)) (!l) (s.onHand (!l) + q) }
  | .expire =>
    if q < s.watermark then .error "nonmonotone_clock" else
    .ok { s with watermark := q, reservations := fun k =>
      (s.reservations k).map fun r =>
        if r.status = .active ∧ r.expires ≤ q then { r with status := .expired } else r }

-- Operation-specific accounting lemmas. No postcondition is used as an admission guard.
theorem receive_safe (s : Stock) (l : Bool) (q : Nat) (hs : Safe s) :
    Safe (updateSlot s l (s.onHand l + q) (s.reservations l)) := by
  apply local_safe _ _ _ _ hs
  have := hs l
  omega

theorem reserve_safe (s : Stock) (l : Bool) (q e : Nat) (hs : Safe s)
    (capacity : q ≤ s.onHand l - held (s.reservations l)) :
    Safe (updateSlot s l (s.onHand l) (some ⟨q, e, .active⟩)) := by
  apply local_safe _ _ _ _ hs
  simp only [held, ↓reduceIte]
  omega

theorem commit_safe (s : Stock) (l : Bool) (r : Reservation) (q : Nat)
    (hs : Safe s) (hr : s.reservations l = some r) (ha : r.status = .active)
    (_hq : q ≤ r.remaining) :
    Safe (updateSlot s l (s.onHand l - q)
      (some { r with remaining := r.remaining - q, status := if r.remaining = q then .committed else .active })) := by
  apply local_safe _ _ _ _ hs
  have h := hs l
  simp [hr, held, ha] at h
  by_cases he : r.remaining = q
  · simp [held, he]
  · simp [held, he]
    omega

theorem close_safe (s : Stock) (l : Bool) (r : Reservation) (status : Status)
    (hs : Safe s) (closed : status ≠ .active) :
    Safe (updateSlot s l (s.onHand l) (some { r with status := status })) := by
  apply local_safe _ _ _ _ hs
  simp [held, closed]

theorem transfer_safe (s : Stock) (l : Bool) (q : Nat) (hs : Safe s)
    (capacity : q ≤ s.onHand l - held (s.reservations l)) :
    Safe { s with onHand := put (put s.onHand l (s.onHand l - q)) (!l) (s.onHand (!l) + q) } := by
  intro k
  have h := hs k
  cases l <;> cases k <;> simp_all [put, Safe] <;> omega

theorem expire_safe (s : Stock) (now : Nat) (hs : Safe s) :
    Safe { s with watermark := now, reservations := fun k =>
      (s.reservations k).map fun r =>
        if r.status = .active ∧ r.expires ≤ now then { r with status := .expired } else r } := by
  intro k
  have h := hs k
  cases hr : s.reservations k with
  | none => simp [hr, held]
  | some r =>
    by_cases he : r.status = .active ∧ r.expires ≤ now
    · simp [hr, he, held]
    · simpa [hr, he] using h

theorem partial_commit_positive (r : Reservation) (q : Nat)
    (hq : q ≤ r.remaining) (ha : (if r.remaining = q then Status.committed else .active) = .active) :
    0 < r.remaining - q := by
  split at ha <;> simp_all <;> omega

theorem transition_safe (s t : Stock) (c : Command) (hs : Safe s)
    (success : transition s c = .ok t) : Safe t := by
  cases hop : c.op <;> simp [transition, hop] at success
  all_goals try split at success
  all_goals try split at success
  all_goals try split at success
  all_goals try split at success
  all_goals cases success
  all_goals try simp_all only [not_or, not_not, Nat.not_lt]
  all_goals first
    | exact receive_safe _ _ _ hs
    | apply reserve_safe _ _ _ _ hs; omega
    | apply local_safe _ _ _ _ hs; simp [held]; done
    | apply local_safe _ _ _ _ hs
      simp only [held]
      split
      · have h := hs c.location
        simp_all [held]
        omega
      · omega
    | exact close_safe _ _ _ .released hs (by decide)
    | apply transfer_safe _ _ _ hs; omega
    | exact expire_safe _ _ hs


theorem transition_positive (s t : Stock) (c : Command) (hs : Positive s)
    (success : transition s c = .ok t) : Positive t := by
  cases hop : c.op <;> simp [transition, hop] at success
  all_goals try split at success
  all_goals try split at success
  all_goals try split at success
  all_goals try split at success
  all_goals cases success
  all_goals first
    | exact hs
    | apply local_positive _ _ _ _ hs
      exact fun r hr ha => hs c.location r hr ha
    | apply local_positive _ _ _ _ hs
      intro r hr ha
      cases hr
      simp_all <;> omega
    | intro l r hr ha
      dsimp only at hr
      cases he : s.reservations l with
      | none => simp [he] at hr
      | some old =>
        by_cases hx : old.status = .active ∧ old.expires ≤ c.quantity
        · simp [he, hx] at hr
          cases hr
          contradiction
        · simp [he, hx] at hr
          exact hs l r (by simpa [he, hx] using hr) ha

structure Ledger where
  stock : Stock
  version : Nat
  seen : List Command

def initial : Ledger := ⟨⟨fun _ => 0, fun _ => none, 0⟩, 0, []⟩

def admit (s : Ledger) (c : Command) : Except String (Ledger × String) :=
  match s.seen.find? (fun prior => prior.id = c.id) with
  | some prior => if prior = c then .ok (s, "duplicate") else .error "idempotency_conflict"
  | none => if c.version ≠ s.version then .error "stale_stock_version" else
    match transition s.stock c with
    | .error e => .error e
    | .ok next => .ok (⟨next, s.version + 1, s.seen ++ [c]⟩, "accepted")

theorem exact_replay (s : Ledger) (c : Command)
    (h : s.seen.find? (fun prior => prior.id = c.id) = some c) :
    admit s c = .ok (s, "duplicate") := by simp [admit, h]

theorem version_conflict (s : Ledger) (c : Command)
    (fresh : s.seen.find? (fun prior => prior.id = c.id) = none)
    (stale : c.version ≠ s.version) : admit s c = .error "stale_stock_version" := by
  simp [admit, fresh, stale]

theorem changed_replay (s : Ledger) (c prior : Command)
    (h : s.seen.find? (fun prior => prior.id = c.id) = some prior)
    (different : prior ≠ c) : admit s c = .error "idempotency_conflict" := by
  simp [admit, h, different]

theorem admitted_invariants (s next : Ledger) (c : Command) (tag : String)
    (hs : Safe s.stock ∧ Positive s.stock)
    (h : admit s c = .ok (next, tag)) : Safe next.stock ∧ Positive next.stock := by
  unfold admit at h
  split at h
  · split at h
    · cases h; exact hs
    · cases h
  · split at h
    · cases h
    · split at h
      · cases h
      · cases h
        exact ⟨transition_safe _ _ _ hs.1 (by assumption),
          transition_positive _ _ _ hs.2 (by assumption)⟩

inductive Reachable : Ledger → Prop where
  | empty : Reachable initial
  | next {s t : Ledger} {c : Command} {tag : String}
      (prior : Reachable s) (accepted : admit s c = .ok (t, tag)) : Reachable t

theorem reachable_invariants {s : Ledger} (h : Reachable s) :
    Safe s.stock ∧ Positive s.stock := by
  induction h with
  | empty => exact ⟨by intro l; simp [initial, held], by intro l r hr; simp [initial] at hr⟩
  | next _ accepted ih => exact admitted_invariants _ _ _ _ ih accepted

-- Independent mathematical negative controls: aggregate capacity hides local
-- overselling; reviving retained closed records restores already-released holds.
def wrongLocation : Stock := ⟨fun l => if l then 3 else 0,
  fun l => if l then none else some ⟨2, 5, .active⟩, 0⟩
example : ¬ Safe wrongLocation := by
  intro h
  have := h false
  simp [wrongLocation, held] at this

example : held (some ⟨2, 5, .released⟩) = 0 ∧ held (some ⟨2, 5, .active⟩) = 2 := by decide

end BizKitInventoryLocations
