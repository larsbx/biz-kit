# Phase 12B — Self-contained bundle trust: in-band checkpoint-key derivation

> **Status: PLANNED** (2026-07-22). Scope is 12A's named follow-up:
> `verify_anchored` currently needs the checkpoint public key delivered
> out-of-band, so the departure bundle is not fully self-contained — the
> member must safeguard a key file beside it. The chapter's `governance`
> stream already carries the whole role-key history from genesis; bundled
> and anchored, it lets the member derive the checkpoint key OFFLINE with
> only the genesis fingerprint as trust root — the same TOFU root §15.2
> already documents, recordable at join. Read-side only; no new event
> types; not blocked by `gate(D)`; no new cryptography.

## Grounding

- `docs/phase12a_plan.md` deferred list ("in-band checkpoint-key
  derivation (bundling the governance stream) — the out-of-band doctrine
  covers v0") and SUBSTRATE.md §15.2 (genesis trust-on-first-use; the
  fingerprint is the documented root), §15.4 (as-of key validation).
- corpus 08 §1: the export is the external-evidence path — evidence
  should not depend on a second artifact traveling a second channel.
- The offline verifier must not trust the operator's gate: the 1D
  authorization rules for the governance stream are re-checked offline
  over the verified envelopes, not assumed.

## Design decisions (flagged)

1. **The bundle carries its own trust chain.** `member_bundle/2` adds the
   chapter's `governance` stream (commons by class). `Export.anchor/2`
   already proofs every bundle stream, so the governance stream is
   automatically completeness-anchored too — a governance history
   truncated to hide a key revocation fails its own inclusion proof.
2. **Derivation re-checks the rules, it does not trust the gate.** A
   small offline fold over the verified governance envelopes replays the
   1D discipline: the FIRST declaration is the genesis governance key,
   self-certified (role-tagged signer == declared key); every later
   `RoleKeyDeclared`/`RoleKeyRevoked` must carry a governance signature
   from a key declared AT THAT POINT; keys are taken as-of the
   checkpoint's `global_seq` (later revocation never invalidates a
   historical attestation — the §15.4 rule, now enforceable offline).
3. **The genesis fingerprint is the only out-of-band bit, and it is
   optional but urged.** `verify_anchored(bundle, opts)`: with
   `genesis_pubkey:` the derived genesis key must match (the member's
   recorded fingerprint); without it the result RETURNS the derived
   genesis key for the caller to compare — trust-on-first-use stated,
   never hidden. The 12A explicit path stays: `checkpoint_pubkey:`
   short-circuits derivation (arity unchanged; the 12A positional-key
   call sites migrate to the option).
4. **Circularity is resolved by the root, stated honestly.** The
   checkpoint key signs the root that anchors the stream that names the
   checkpoint key. That loop is sound exactly because the genesis key
   pins the stream's identity: forging an alternative governance history
   requires the genesis key — the same trust boundary the substrate has
   documented since 1D, now mechanically checkable by a member offline.

## Acceptance [12B]

1. **Fully self-contained verification.** A bundle anchored at a fresh
   checkpoint verifies offline with NO key material passed in; the
   result carries the derived genesis key; passing the correct
   `genesis_pubkey:` succeeds and a wrong one is rejected
   (`:genesis_mismatch`).
2. **The derivation obeys the 1D rules offline.** A checkpoint signed by
   a key revoked before the checkpoint position is rejected
   (`:checkpoint_key_not_declared`-shaped); one signed by a key declared
   later than the position is rejected; rotation histories (declare →
   revoke → declare) derive correctly as-of.
3. **Governance-history truncation is caught.** Dropping the tail of the
   bundled governance stream (e.g. hiding a revocation) fails anchored
   verification on that stream's own proof.
4. **Compatibility.** The explicit `checkpoint_pubkey:` path behaves
   exactly as 12A shipped; bundles without a governance stream fail
   derivation with a distinct error rather than silently degrading.
5. **Classified; suite green.** No new public query beyond the changed
   `verify_anchored` options; existing classifications hold.

## Build steps

1. Add this plan and commit it before implementation.
2. `member_bundle/2`: include the chapter `governance` stream (omitted
   when empty, like rule streams — a chapter with no declared roles has
   nothing to derive and the out-of-band path remains).
3. The offline role-key fold in `Export` (private): genesis
   self-certification, governance-signed successors, revocations, as-of
   cut at the checkpoint position.
4. `verify_anchored/2` options: `checkpoint_pubkey:` (12A path),
   `genesis_pubkey:` (pinned derivation), default (derive + return
   genesis key). Update 12A call sites and tests.
5. `test/self_contained_bundle_test.exs` (acceptance 1–4); full suite;
   commit only if green.
6. SUBSTRATE.md §15.4/§7 notes; 12A plan's deferred list annotated.

## Explicitly deferred

- Sync/replication uses of the stream-heads root (unchanged).
- As-of anchored exports (dispute-workflow trigger, unchanged).
- Fingerprint UX (how members record the genesis key at join —
  operational practice, not mechanism).
