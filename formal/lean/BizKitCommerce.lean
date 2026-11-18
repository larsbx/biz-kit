import Lean

/-!
# Proof Bank obligation: CommerceCore tax shares conserve exact minor units

Models `CommerceCore.Tax.flat/4` and its private `allocate/4`
(apps/commerce_core/lib/commerce_core/tax.ex) over natural-number minor units.
A rate is `num / den` with `0 < den` (`fraction/1` also requires `num < den`;
the theorem does not need it). With taxable bases `bᵢ`:

* `total = (2·Σbᵢ·num + den) / (2·den)`  (half-up, once per order)
* `floorᵢ = bᵢ·num / den`, `extra = total − Σ floorᵢ`
* the shares are the floors, plus one minor unit for `extra` chosen indices.

The Elixir code picks the `extra` largest remainders, ties going to the
earlier index. The theorem holds for **every** choice of exactly `extra`
indices, so it does not depend on that sort or its tie-breaking. A `mask`
marks the chosen indices.

Proved: `extra` lies within `[0, n]`, so a valid choice always exists, and the
shares sum exactly to `total`. Not proved: `Money`/`Decimal` conversion,
currency checks, `Pricing.price/3`, or that the Elixir code refines this model.
-/

namespace BizKitCommerce

def floors (num den : Nat) (bases : List Nat) : List Nat := bases.map (· * num / den)
def rems (num den : Nat) (bases : List Nat) : List Nat := bases.map (· * num % den)

def total (num den : Nat) (bases : List Nat) : Nat := (2 * (bases.sum * num) + den) / (2 * den)
def extra (num den : Nat) (bases : List Nat) : Nat := total num den bases - (floors num den bases).sum

/-- `allocate/4`: each floor, plus one where the mask chose the index. -/
def shares (num den : Nat) (bases : List Nat) (mask : List Bool) : List Nat :=
  List.zipWith (fun b m => b * num / den + if m then 1 else 0) bases mask

theorem decompose (num den : Nat) (bases : List Nat) :
    bases.sum * num = den * (floors num den bases).sum + (rems num den bases).sum := by
  induction bases with
  | nil => simp [floors, rems]
  | cons b bs ih =>
    simp only [floors, rems, List.map_cons, List.sum_cons] at *
    have h := Nat.div_add_mod (b * num) den
    rw [Nat.add_mul, ih, Nat.mul_add]
    omega

theorem rems_bound (num den : Nat) (bases : List Nat) (hden : 0 < den) :
    (rems num den bases).sum ≤ bases.length * den := by
  induction bases with
  | nil => simp [rems]
  | cons b bs ih =>
    simp only [rems, List.map_cons, List.sum_cons, List.length_cons] at *
    have := Nat.mod_lt (b * num) hden
    rw [Nat.succ_mul]
    omega

/-- The rounded total is the floor sum plus a carry from the remainders. -/
theorem total_split (num den : Nat) (bases : List Nat) (hden : 0 < den) :
    total num den bases =
      (floors num den bases).sum + (2 * (rems num den bases).sum + den) / (2 * den) := by
  unfold total
  rw [decompose num den bases]
  have : 2 * (den * (floors num den bases).sum + (rems num den bases).sum) + den =
      (2 * (rems num den bases).sum + den) + 2 * den * (floors num den bases).sum := by
    rw [Nat.mul_add, ← Nat.mul_assoc]; omega
  rw [this, Nat.add_mul_div_left _ _ (by omega)]
  omega

/-- `extra ≤ n`: there are always enough indices to receive the carry. -/
theorem extra_le_length (num den : Nat) (bases : List Nat) (hden : 0 < den) :
    extra num den bases ≤ bases.length := by
  unfold extra
  rw [total_split num den bases hden, Nat.add_sub_cancel_left]
  have hr := rems_bound num den bases hden
  apply Nat.le_of_lt_succ
  rw [Nat.div_lt_iff_lt_mul (by omega)]
  have h2 : (bases.length + 1) * (2 * den) = 2 * (bases.length * den) + 2 * den := by
    rw [Nat.add_mul, Nat.one_mul, Nat.mul_left_comm]
  show _ < (bases.length + 1) * (2 * den)
  omega

theorem shares_sum (num den : Nat) (bases : List Nat) (mask : List Bool)
    (hlen : mask.length = bases.length) :
    (shares num den bases mask).sum = (floors num den bases).sum + mask.count true := by
  induction bases generalizing mask with
  | nil => cases mask <;> simp_all [shares, floors]
  | cons b bs ih =>
    cases mask with
    | nil => simp at hlen
    | cons m ms =>
      simp only [List.length_cons, Nat.succ.injEq] at hlen
      have := ih ms hlen
      simp only [shares, floors, List.zipWith_cons_cons, List.map_cons, List.sum_cons,
        List.count_cons] at *
      cases m <;> simp <;> omega

/-- **Obligation.** The tax shares conserve the order's tax exactly: for any
choice of exactly `extra` indices, the shares sum to the rounded total, and
such a choice always exists. -/
theorem obligation (num den : Nat) (bases : List Nat) (mask : List Bool) (hden : 0 < den)
    (hlen : mask.length = bases.length) (hcount : mask.count true = extra num den bases) :
    (shares num den bases mask).sum = total num den bases ∧ extra num den bases ≤ bases.length := by
  refine ⟨?_, extra_le_length num den bases hden⟩
  rw [shares_sum num den bases mask hlen, hcount]
  have ht := total_split num den bases hden
  have hx : extra num den bases = total num den bases - (floors num den bases).sum := rfl
  generalize (2 * (rems num den bases).sum + den) / (2 * den) = carry at ht
  omega

/-- Negative control: rounding each share half-up on its own does not conserve.
Two bases of one minor unit at rate 1/2 total 1, but naive shares sum to 2. -/
def naiveShares (num den : Nat) (bases : List Nat) : List Nat :=
  bases.map (fun b => (2 * b * num + den) / (2 * den))

theorem naive_rounding_counterexample :
    (naiveShares 1 2 [1, 1]).sum ≠ total 1 2 [1, 1] := by decide

/-- Fixture: `allocate/4` at 1/2 on [1, 1] carries the one unit to index 0. -/
example : shares 1 2 [1, 1] [true, false] = [1, 0] ∧ total 1 2 [1, 1] = 1 := by decide

end BizKitCommerce
