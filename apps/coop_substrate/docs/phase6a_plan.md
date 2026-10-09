# Phase 6A — Secure modular substrate foundation

> **Status: COMPLETE** (2026-07-19). Scope was the secure modular substrate
> foundation; acceptance **[6A]** passes: the mechanism ladder is typed data
> (`Privacy.Mechanism`) with unsupported rung/boundary/workload combinations
> unrepresentable; all three privacy seams expose validated backing descriptors
> with caller APIs unchanged; long-running/unbounded workloads are sidecar-only
> by data; SUBSTRATE.md §17 names the portable API surface, freight modules as
> consumers, and the agent proof/descriptor contract. No HE/ZK/MPC/FHE code was
> built (08 §9). This phase was never blocked by `gate(D)` — that gate only
> protects the Dispatch-D build.

## Grounding

- `docs/corpus/08_PLATFORM.md`: event substrate, structural enforcement, privacy
  mechanism ladder (plain signatures -> k-anonymity -> additive HE -> ZK ->
  nullifiers), sidecar boundary, agent guards, LLM minimization.
- `docs/handoff.md` §4/§4a: privacy interfaces first; heavy crypto staged
  behind swappable seams; proving/FHE/MPC sidecar-only when unbounded or
  long-running.
- `SUBSTRATE.md` §7, §13, §15: canonical log, key governance, checkpoint
  signatures, `Privacy.Aggregate`, `Privacy.Proof`, `Privacy.JointCompute`, and
  current open questions.
- Existing code: `lib/coop_substrate/privacy/*`, `Protocol.TypeRegistry`,
  `Protocol.Validity`, `Log`, `Projection`, and the no-surveillance tests.

## §0 Spine

```
portable substrate =
  canonical signed log
  + append-gate type registry
  + pure replay projections
  + explicit privacy mechanism descriptors
  + sidecar-safe crypto seams
  + agent capability/proof boundary

advanced crypto enters only as a declared backing:
  additive HE -> aggregate sums when k/plain fails
  ZK proofs   -> portable third-party verification when trusted audit fails
  MPC/FHE     -> joint compute sidecar when cross-party matching needs it
```

The work is representability and modularity first. No production HE/ZK circuit
or FHE engine is built in this phase; premature crypto remains a defect.

## Acceptance [6A]

1. **Privacy mechanism descriptors.** The substrate has a small typed registry
   describing mechanism rungs (`plain`, `k_anonymity`, `additive_he`, `zk`,
   `mpc`, `fhe`, `nullifier`) and their allowed execution boundary
   (`beam`, `bounded_nif`, `dirty_nif`, `sidecar`). Unsupported combinations are
   unrepresentable.
2. **Backings declare their rung.** `Privacy.Aggregate`, `Privacy.Proof`, and
   `Privacy.JointCompute` expose/require metadata for the backing in use so an
   app or agent can inspect whether it is relying on trusted audit, HE, ZK, or a
   sidecar, without changing caller code.
3. **Sidecar boundary is enforced as data.** Long-running proof generation,
   MPC/FHE evaluation, and unbounded input crypto can only be declared as
   `sidecar`; bounded verification remains eligible for BEAM/NIF paths.
4. **Agent collaboration contract.** Agent-facing modules consume substrate
   proofs/checkpoints/capability facts, not raw private member streams. Any
   future agent action that needs private facts must ask for a `Privacy.Proof`
   or `Privacy.JointCompute` result and carry its mechanism descriptor.
5. **Portability checklist.** `SUBSTRATE.md` names the stable substrate API
   surface that other applications may depend on, and names freight-specific
   modules as consumers rather than substrate core.
6. **Regression tests.** The suite fails if a new mechanism descriptor violates
   the boundary rules, if a backing lacks metadata, or if callers bypass the
   privacy seams for cross-member aggregate/proof/joint-compute work.

## Build steps

1. Add this plan and commit it before implementation.
2. Add a minimal `CoopSubstrate.Privacy.Mechanism` module with pure validation
   data and tests. Keep it dependency-free.
3. Add backing metadata to `Privacy.Aggregate`, `Privacy.Proof`, and
   `Privacy.JointCompute`; preserve existing caller APIs.
4. Extend the privacy seam tests so the default trusted/auditable backings and
   test backings declare valid descriptors.
5. Update `SUBSTRATE.md` with the Phase 6A API boundary and HE/ZK sidecar
   escalation rules.
6. Run the focused privacy tests and full suite. Commit only if green.

## Explicitly deferred

- Real Paillier/additive-HE implementation.
- Real ZK circuits or nullifier schemes.
- MPC/FHE sidecar process implementation.
- Agent runtime integration beyond the substrate contract.
- Any dispatch-specific Phase 4A work still gated by `gate(D)`.
