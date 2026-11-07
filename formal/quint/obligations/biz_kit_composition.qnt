// biz_kit_composition: "A preview never implies a committed reservation, sale
// or delivery."
//
// Models BizKit.Composition.preview/3 (apps/biz_kit_composition/lib/biz_kit/
// composition.ex): it quotes the catalog, prices an estimate, and runs
// InventoryCore.apply/3 for the reserve command but discards the next state
// (`{:ok, _next, :accepted}`). It returns `kind: :unsigned_preview` with
// candidate commands. Committed facts change only when a host admits a signed
// command (abstracted here as `admit`).
// Abstracted: one item, unit quantities, sale and delivery as counters.
// GUARDED switches off the discard: the control keeps the reserved `_next`
// and treats the preview's sale and handoff as committed.
module biz_kit_composition_spec {
  const GUARDED: bool

  var reserved: int     // committed reservations
  var sold: int         // committed sales
  var delivered: int    // committed handoffs
  var admitted: int     // signed commands a host admitted
  var previews: int

  action init = all { reserved' = 0, sold' = 0, delivered' = 0, admitted' = 0, previews' = 0 }

  action preview = all {
    previews' = previews + 1,
    reserved' = if (GUARDED) reserved else reserved + 1,
    sold' = if (GUARDED) sold else sold + 1,
    delivered' = if (GUARDED) delivered else delivered + 1,
    admitted' = admitted,
  }

  // A host admits one signed candidate: reservation, sale and handoff together.
  action admit = all {
    admitted' = admitted + 1, reserved' = reserved + 1, sold' = sold + 1,
    delivered' = delivered + 1, previews' = previews,
  }

  action step = any { preview, admit }

  // Every committed fact is backed by an admitted command, however many previews.
  val obligation = reserved <= admitted and sold <= admitted and delivered <= admitted

  // Previews were made and nothing was admitted.
  val obligationWitness = not(previews >= 2 and admitted == 0)
}

module biz_kit_composition {
  import biz_kit_composition_spec(GUARDED = true).*
}

module biz_kit_composition_control {
  import biz_kit_composition_spec(GUARDED = false).*
}
