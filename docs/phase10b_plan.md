# Phase 10B — Governance recovery rotation: a lost key is not a lost identity

> **Status: PLANNED** (2026-07-21). Scope is the SUBSTRATE.md §8 item
> flagged since 1D: "a member's lost key currently means a lost identity;
> social recovery / governance-signed rotation variants are open
> (08 §10.3)." This phase builds the **governance-signed variant** as v0
> mechanism and defers social recovery. Not blocked by `gate(D)`; no new
> cryptography (08 §6: social recovery would mean threshold/guardian
> crypto with no demonstrated failure of the lighter rung — the lighter
> rung here is signatures we already have plus review structure we
> already built).

## Grounding

- `SUBSTRATE.md` §8 (the flagged gap) and the 1D `KeyRotated` discipline:
  self-rotation chains from the *current* key — exactly what a member with
  a lost key cannot produce.
- `docs/corpus/08_PLATFORM.md` §10.3 (open item: key rotation and
  social-recovery UX) and §6 (escalate mechanism only on demonstrated
  need).
- Built machinery this composes from: the 1D role-key registry
  (bootstrap-then-enforce; genesis governance), the 5A R-item rail
  (decision-ready evidence packets), the 9B consumption contract (an
  approved item authorizes exactly one consequent event, structurally
  referenced), and the `MemberRegistered` self-certification pattern.

## Design decisions (flagged)

1. **No single actor can rotate someone's identity.** `KeyRecoveryRotated`
   requires ALL of:
   - an R item `recovery/<member_id>/<new_key_id>` raised with an
     identity-evidence packet (process `key_recovery`) and resolved
     **approved** — the human review, on the log, consumable once by
     construction (the item authorizes exactly that key; after rotation
     the key is current and a replay rejects on `new == current`);
   - a **governance-role signature**, valid against the declared registry —
     recovery is therefore unrepresentable in a chapter that has never
     declared governance keys (`:governance_undeclared`; genesis-trust
     chapters must grow up before anyone can be recovered);
   - the **new key's own signature** self-certifying possession (the
     `MemberRegistered` pattern): governance attests identity, never
     holds the key.
2. **The old key is not consulted.** It is lost; requiring it would defeat
   the mechanism. Its invalidation is automatic: `check_member_signature`
   follows the members fold, which the rotation updates — stale-key
   signatures reject exactly as after a normal `KeyRotated`.
3. **Visibility is the takeover mitigation.** The rotation rides the
   member's own `keys` stream (exported in their bundle); the R item and
   its packet are the contest surface. A time-delay/challenge window is
   deferred — it needs an in-log time authority the substrate deliberately
   lacks (no clock in any fold), and the R review is the v0 safeguard.
4. **Social recovery stays unbuilt** (guardian sets, thresholds — new
   cryptography and new governance semantics; 08 §6 says not until the
   lighter rung demonstrably fails).

## Acceptance [10B]

1. **The full path works.** Evidence item raised → resolved approved →
   dual-signed `KeyRecoveryRotated` (governance + new key) lands; the old
   key immediately stops signing (lifecycle event rejected
   `:not_the_members_current_key`); the new key signs lifecycle events
   and a subsequent normal `KeyRotated` chains from it.
2. **Every leg is load-bearing.** Missing/unresolved/declined item, item
   for a different member or a different new key, absent governance
   declaration, missing new-key self-signature, undeclared governance
   signer key, and `new == current` are each rejected before persistence.
3. **Recovery is repeatable but never replayable.** A second recovery
   with a fresh item and fresh key succeeds; re-citing a consumed item
   (same key) rejects.
4. **No surveillance surface change.** No new queries; the event is
   commons-classed on the member's `keys` stream like `KeyRotated`.

## Build steps

1. Add this plan and commit it before implementation.
2. Registry: `KeyRecoveryRotated{member_id, new_key_id, new_pubkey,
   authorization_item_id}` — required roles `["member", "governance"]`,
   stream `keys/<member_id>`.
3. Gate: the composed check (registered member; governance declared;
   item `recovery/<member_id>/<new_key_id>` resolved approved on process
   `key_recovery`; new-key self-certification; `new != current`).
4. Projection: update the member's current key (the `KeyRotated` shape).
5. `test/key_recovery_test.exs` (acceptance 1–3); full suite; commit
   only if green.

## Explicitly deferred

- Social recovery (guardian thresholds) — 08 §6 gated on demonstrated
  failure of this rung.
- A challenge/delay window before the rotation takes effect (needs a
  time authority; the R review + own-stream visibility is v0).
- Recovery of *role* keys (governance/steward/checkpoint) — already
  governed by the 1D declare/revoke registry, a different door.
- Recovery UX (how the member proves identity off-log — operational;
  the packet refs carry whatever counsel/practice settles on).
