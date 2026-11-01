# Proof Bank pilot I-1 — InventoryCore arithmetic and proof refinement

**Status: candidate, not yet proved at CI and not a verified implementation.**

The first first-party proof target is deliberately narrower than the complete
InventoryCore application: **one merchant/item/unit and one location** with
exact natural-number `onHand` and sum of active reservation `held`.

Source under review:
- `apps/inventory_core/lib/inventory_core.ex`: real `apply/3`,
  `transition/2`, `available/3`, `check/2`.
- `formal/lean/BizKitInventory.lean`: abstract arithmetic operations with
  guarded `reserve`, `commit`, `release`, `receive`, induction over
  admitted abstract steps, and a negative-control unguarded reservation.
- `apps/inventory_core/test/proof_bank_inventory_contract_test.exs`:
  **real** Elixir `InventoryCore.apply` conformance probes across
  `onHand=0..15`, reservation sizes `1..16`, partial commits, release,
  failure refusal, idempotency and optimistic version mismatch.

## Intended safety contract (owner review required)

At any observed single location, the sum of active holds is at most
`onHand`. An accepted reservation raises held quantity by at most available
unheld stock, a commit decreases both on-hand and outstanding holds by the
committed amount, release only drops outstanding holds, and receiving stock
increases on-hand. Rejected operations do not become accepted effects.

Abstract state: `Stock(onHand : Nat, held : Nat)`. Invariant:
`held ≤ onHand`. The Lean `Reachable` relation contains only
successful abstract transitions. No unsigned agent outputs or proofs may
change the live stock database.

## What this **does not** prove

- The Lean abstract-state proof does not establish that actual
  `InventoryCore.apply/3` implements this model on *all* inputs.
  The Elixir test is a bounded, falsifiable check of representative
  inputs and the negative control, not a verified refinement.
- The model omits duplicate command IDs, optimistic versions, multi-location
  stock, transfers, adjustment approvals, expiry, retailer/tenant scope,
  merchant auth, and cross-aggregate basket atomicity. Those require
  additional models and source-level or live integration evidence.
- The current module does not own a database, signature authority or
  stock locking. Only an authenticated and serialized host can make a
  proposal authoritative. A successful `Basket.plan/7` does not reserve
  stock.
- No `sorry`, new axioms or unverified oracle results are permitted.
  Kernel replay and all-module axiom audits must pass at the pinned Lean
  toolchain before advertising a verified abstract theorem.

## Acceptance checklist

1. The exact-head Lean workflow executes `lake build`,
   `leanchecker --fresh BizKitInventory` and the existing axiom audit.
2. Exact-head InventoryCore Mix tests pass, including the new real-code
   matrix and existing replay/basket cases.
3. The domain owner approves the exact intended requirement and its
   assumptions, then compares **counterexample** fixtures to the code.
4. A future implementation refinement layer binds the abstract step
   relation to actual Elixir transitions (including malformed states and
   concurrency), not merely the module name.
5. A host-level test proves serialized expected-version admission and
   permanent idempotency under concurrent transactions; this is separately
   blocked until the real Inventory host exists.

No CI results are asserted in this design document.
