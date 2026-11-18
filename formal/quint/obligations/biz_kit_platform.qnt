// biz-kit: "Every business effect passes exactly its owner's authenticated
// admission path".
// Abstracts CoopSubstrate.Log.append/2 (action admit), the single serialized appender:
// TypeRegistry.spec/1 refuses unregistered types (:unknown_type),
// Envelope.verify/1 refuses unauthenticated signatures, verify_validity/2
// runs the type's own check (TypeRegistry.validity_check/2 dispatching on the
// envelope type to its owning domain, e.g. TaskCore.Admission), and
// duplicate/2 + check_batch_event_ids/1 refuse a second append of one
// event_id.
// FINDING: this holds for effects admitted through the Log only. Dispatch,
// eatsbot and spruce_goose still write their own databases directly
// (docs/architecture/2026-10-11-single-source-of-truth.md lists them as
// removal targets), so the platform-wide obligation is not enforced today.
// Abstracted away: two event types, each with one owner; the submitter picks
// a route (which owner's check it asks for) and whether it is signed.
// GUARDED switches off the registry, signature, owner-dispatch and
// duplicate checks.
module biz_kit_platform_spec {
  const GUARDED: bool
  val TYPES = Set("task", "order")
  val ROUTES = Set("task", "order", "none")
  type Effect = { id: int, ty: str, route: str, signed: bool }
  // The owning admission check for each type is named after the type.
  pure def owner(t: str): str = t

  var committed: Set[Effect]
  var refused: int

  action init = all { committed' = Set(), refused' = 0 }

  action admit(id, ty, route, signed) = {
    val ok = TYPES.contains(ty) and signed and route == owner(ty)
             and committed.forall(e => e.id != id)
    if (ok or not(GUARDED)) all {
      committed' = committed.union(Set({ id: id, ty: ty, route: route, signed: signed })),
      refused' = refused,
    } else all { committed' = committed, refused' = refused + 1 }
  }

  action step =
    nondet id = 1.to(2).oneOf()
    nondet ty = Set("task", "order", "unknown").oneOf()
    nondet route = ROUTES.oneOf()
    nondet signed = Set(true, false).oneOf()
    admit(id, ty, route, signed)

  // Every committed effect is a registered type, authenticated, admitted by its
  // owner's check, and committed once.
  val obligation = committed.forall(e =>
      TYPES.contains(e.ty) and e.signed and e.route == owner(e.ty)
      and committed.forall(f => f.id == e.id implies f == e))
  // An effect was committed and an off-path or unauthenticated append was refused.
  val obligationWitness = not(committed.size() > 0 and refused > 0)
}

module biz_kit_platform { import biz_kit_platform_spec(GUARDED = true).* }
module biz_kit_platform_control { import biz_kit_platform_spec(GUARDED = false).* }
