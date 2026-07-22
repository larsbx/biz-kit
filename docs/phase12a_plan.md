# Phase 12A — Anchored exports: stream-heads root on checkpoints

> **Status: PLANNED** (2026-07-22). Scope is the SUBSTRATE.md §8 item
> deferred in 1D — "checkpoint covers the global head only; per-stream
> roots await a partial-verification or sync consumer" — whose
> precondition the 6B departure bundle has since met: the bundle IS the
> partial-verification consumer. Today a prefix-truncated stream still
> verifies offline (chains and signatures hold on any prefix; withheld
> tail events are undetectable), which quietly weakens the §7/§14
> "verify offline forever" promise. Not blocked by `gate(D)`; no new
> cryptographic primitive (a SHA-256 hash tree over data already hashed —
> the chains themselves are hash chains; 08 §6 untriggered).

## Grounding

- SUBSTRATE.md §8 (the deferral, condition now met), §15.4 (CheckpointV1,
  as-of key validation), §7/§14 (the member export promise), and
  corpus 08 §1 (signed per-owner log export as the external-evidence
  path — evidence must be complete, not merely consistent).
- The no-surveillance discipline: a flat stream-heads list would leak the
  chapter roster (stream ids name members). Inclusion proofs leak only
  sibling hashes — that is why the root is a tree, not a list.

## Design decisions (flagged)

1. **CheckpointV2, old blobs verify forever.** `Log.checkpoint/3` now
   emits `CheckpointV2` = V1 fields + `stream_heads_root`: the Merkle
   root over the chapter's per-stream last-event hashes as of the
   checkpoint position (sorted leaves, domain-separated node hashing).
   `Log.verify_checkpoint/1` verifies V1 blobs exactly as before and
   additionally recomputes the root for V2 — the §1.3 spirit applied to
   the blob format.
2. **Anchoring is a store-side act; verification is fully offline.**
   `Export.anchor(bundle, checkpoint_blob)` attaches the checkpoint and
   one inclusion proof per bundle stream (it consults the store; it runs
   where the export runs). `Export.verify_anchored(bundle, pubkey)` is
   pure over its inputs: per-stream decode/signature/chain checks (6B),
   then each stream's LAST event hash proves into the signed root — a
   withheld tail is now detectable offline.
3. **Key distribution rides the existing doctrine.** The verifier
   supplies the checkpoint public key out-of-band — the same channel
   §15.2 already prescribes for the genesis mitigation. Embedding the
   governance stream in the bundle (deriving the key in-band from the
   TOFU root) is a follow-up, not v0.
4. **Anchor-at-head only.** The bundle and checkpoint must describe the
   same position (`:bundle_not_at_checkpoint` otherwise); as-of exports
   stay deferred with the same trigger as before (a dispute workflow).

## Acceptance [12A]

1. **The gap closes.** A bundle with a stream's last record removed still
   passes 6B `Export.verify/1` (proving the gap was real) and FAILS
   `verify_anchored/2` with a head mismatch for exactly that stream.
2. **The honest path is fully offline.** Anchor at a fresh checkpoint;
   `verify_anchored/2` succeeds given only (bundle, pubkey) — no store
   access — and returns the decoded streams like `verify/1`.
3. **Checkpoints stay sound.** V2 round-trips through
   `Log.verify_checkpoint/1` (root recomputed); a V1-shaped blob still
   verifies; a tampered root, tampered signature, or wrong-chapter
   checkpoint is rejected; anchoring against a stale checkpoint errors.
4. **No roster leak.** An anchored bundle contains no stream id beyond
   the member's own bundle streams — proofs carry sibling hashes only
   (pinned structurally in the test).
5. **Classified; suite green.** `anchor/2` own_data, `verify_anchored/2`
   system; full suite green.

## Build steps

1. Add this plan and commit it before implementation.
2. `CoopSubstrate.Protocol.StreamRoot` — sorted-leaf, domain-separated
   SHA-256 tree: `root/1`, `prove/2`, `proven?/4`. Pure.
3. `Log.stream_heads/2` (chapter, `as_of:`) and the V2 emit/verify in
   `Log.checkpoint/3` / `Log.verify_checkpoint/1`.
4. `Export.anchor/2` + `Export.verify_anchored/2`; no-surveillance
   entries.
5. `test/anchored_export_test.exs` (acceptance 1–4); full suite; commit
   only if green.
6. SUBSTRATE.md: §8 item resolved, §15.4 V2 note, §7 export answer
   updated. HARNESS.md: fix the discovery-rule wording — the current
   stage is the plan with the highest **numeric** phase id (lexical
   `ls` ordering breaks at double digits: phase9b sorts after phase11b).

## Explicitly deferred

- In-band checkpoint-key derivation (bundling the governance stream) —
  the out-of-band doctrine covers v0.
- As-of anchored exports (dispute-workflow trigger, unchanged).
- Sync/replication uses of the root (the other §8 consumer; a later
  brief).
