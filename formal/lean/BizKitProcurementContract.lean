namespace BizKit.ProcurementContract

inductive Family where
  | wakalah | musawamah | tawliyah
  deriving DecidableEq

structure Case where
  family : Family
  member : Nat
  cooperative : Nat
  supplier : Nat
  purchaseBuyer : Nat
  quotedSeller : Nat
  currentMandate : Bool
  titleBeforeResale : Bool
  goodsPrice : Nat
  assertedCost : Option Nat
  originalGoodsCost : Option Nat

def Common (c : Case) : Prop :=
  c.member ≠ c.cooperative ∧ c.member ≠ c.supplier ∧ c.cooperative ≠ c.supplier

def Eligible (c : Case) : Prop :=
  Common c ∧
    match c.family with
    | .wakalah => c.purchaseBuyer = c.member ∧ c.quotedSeller = c.supplier ∧
        c.currentMandate = true ∧ c.assertedCost = none
    | .musawamah => c.purchaseBuyer = c.cooperative ∧ c.quotedSeller = c.cooperative ∧
        c.titleBeforeResale = true ∧ c.assertedCost = none
    | .tawliyah => c.purchaseBuyer = c.cooperative ∧ c.quotedSeller = c.cooperative ∧
        c.titleBeforeResale = true ∧ c.assertedCost = some c.goodsPrice ∧
        c.originalGoodsCost = some c.goodsPrice

theorem wakalah_requires_member_purchase (c : Case) (h : Eligible c)
    (family : c.family = .wakalah) :
    c.purchaseBuyer = c.member ∧ c.purchaseBuyer ≠ c.cooperative ∧ c.currentMandate = true := by
  have roles := h.2
  simp only [family] at roles
  exact ⟨roles.1, roles.1 ▸ h.1.1, roles.2.2.1⟩

theorem principal_requires_cooperative_title (c : Case) (h : Eligible c)
    (family : c.family ≠ .wakalah) :
    c.purchaseBuyer = c.cooperative ∧ c.purchaseBuyer ≠ c.member ∧
    c.quotedSeller = c.cooperative ∧ c.titleBeforeResale = true := by
  have roles := h.2
  cases hf : c.family with
  | wakalah => exact False.elim (family hf)
  | musawamah =>
    simp only [hf] at roles
    exact ⟨roles.1, roles.1 ▸ Ne.symm h.1.1, roles.2.1, roles.2.2.1⟩
  | tawliyah =>
    simp only [hf] at roles
    exact ⟨roles.1, roles.1 ▸ Ne.symm h.1.1, roles.2.1, roles.2.2.1⟩

theorem tawliyah_requires_original_goods_cost (c : Case) (h : Eligible c)
    (family : c.family = .tawliyah) :
    c.assertedCost = some c.goodsPrice ∧ c.originalGoodsCost = some c.goodsPrice := by
  have roles := h.2
  simp only [family] at roles
  exact roles.2.2.2

-- Abstract the serialized read: its only output is a decision, and
-- accounting authority lives in the existing state.
def review (c : Case) [Decidable (Eligible c)] (accountingAuthority : α) :
    Bool × α :=
  (decide (Eligible c), accountingAuthority)

theorem review_preserves_accounting_authority (c : Case) [Decidable (Eligible c)] (a : α) :
    (review c a).2 = a := rfl

end BizKit.ProcurementContract
