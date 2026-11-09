# Commercial source-bound admission proof — 2026-11-08

Status: **research-only source-fence specification and pure reference**, no
production accounting writer or financial settlement. Tracks
[biz-kit #299](https://github.com/larsbx/biz-kit/issues/299) and its parent
[audit #290](https://github.com/larsbx/biz-kit/issues/290).

## Architectural decision

In-network contractual clearance is the primary economic goal. All actual
commercial debts must remain attributable to their owners. A proposed
netting plan and its accounting journal are *not* equivalent to legally
effective setoff, and a successful proof replay is not an authorized bank
transfer.

The existing `CoopSubstrate.Log` is the sole signed business append gate.
`larsbx/hawala-core` owns financial credits, custody, and native financial
commit; this PR creates neither a competing writer nor a money transmitter.

The historical `NettingExecuted` event signs aggregate pair figures only.
It does **not** bind individual source obligation IDs and digests, and can
therefore accept a substituted same-total source set. The `CommercialSetoffProof`
and `CommercialSetoffSources` modules merged in PR #298 are inert cryptographic
checks, not serialized admission or legal authorization.

## State machine modeled

For each chapter, the future signed business admission will maintain:

- A set of consumed **(chapter, original obligation ID)** keys. The source's
  revision and hash must be authenticated, but another revision cannot
  reopen an already consumed original ID.
- A set of accepted **(chapter, clearing intent ID)** keys and the corresponding
  exact signed commitment, with replay but no duplicate journal admission.
- A count or historical trace of actual accepted business events.

Admission must be an atomic transaction that, before recording a new event,
verifies all of the following as **independently established facts**:
the complete sorted source set and current revisions; authentic source and
entity authorizations; exact approval by all affected principals; legally
effective discharge terms; jurisdiction/activity/sanctions policy eligibility;
a fresh intent; and non-overlap with already consumed source keys.

The proposed reference transition is:

```text
if authoritative_evidence_and_policy_verified
   and exact_source_set_is_nonempty
   and intent_is_fresh
   and every_source_is_unconsumed:
     atomically record intent + consume entire source set + append one
     signed business event
else:
     preserve prior state
```

No partial consumption is allowed. Unknown or disputed outcomes must be
held rather than assumed committed. An unchanged retry may return an
existing receipt but cannot create another event. Different terms under the
same intent are a conflict, not a retry.

## Proof and adversarial surfaces

**Lean 4, `BizKitCommercialSetoff`:** universal theorems over **exactly two
original source IDs per admission**, encoded with chapter-qualified identities
and boolean membership functions (no unavailable `Finset` dependency).
The theorems cover absent-evidence refusal, distinct-source requirement,
accepted intent/source marking, duplicate-intent stuttering, and refusal
of a competing second admission sharing the first source. This is narrower
than a proof over arbitrary multilateral source sets. The model captures
the atomic admission ideal; it does not prove that the present Elixir writer
refines that ideal.

**Quint, `commercial_source_fence.qnt`:** bounded nondeterministic traces
with three abstract source IDs, repeated intent IDs, lost reply/restart
stuttering, varying source-binding and authorization flags. The invariant
checks accepted verification premises, no duplicate intent or overlapping
source use, and correspondence of the consumed set to admission history.
Nonvacuity requires both accepted and refused attempts; removing the guard
must yield a counterexample, not merely a tool error.

**Pure Elixir, `BarterCore.SourceBoundFence`:** independent in-memory
reference exposing the same intent/revision/source conflict and replay
behavior. It accepts test-only caller-provided Boolean claims and must
never authorize a real operation. There is no persistent fence or network
endpoint and no need for bank access.

## What is still unverified or prohibited

1. Current corporate agency and legally effective contractual release are
   **external factual predicates**. Cryptographic signatures or opaque
   policy digests alone cannot establish them.
2. Current source revision and signer evidence must be reconstructed from
   independently authenticated authority history at the commit instant;
   a stale read-only snapshot cannot serve as the serialized gate.
3. The actual business Log must gain a versioned event whose *signed bytes*
   bind exact sources, checks, consents and effective evidence, and whose
   serialized gate atomically updates the source/intent fences.
4. The existing aggregate-signed `NettingExecuted` must be disabled for
   any future source-bound execution profile without invalidating historic
   signed events or silently changing existing pairwise behavior.
5. Multi-node partial failures, crash recovery, fencing, regulatory decision
   inputs, insolvency, cross-currency conversion and financial finality are
   outside this proof. They require independent verification.
6. Neither a pure model nor hosted CI certifies that an operation is exempt
   from money-transmitter licensing. Every enabled activity must be
   jurisdiction- and actor-scoped.

## Exact-head acceptance

The source-fence workflow pins Quint 0.32.0 and the repository's
checksum-verified Lean 4.35.0 toolchain. Require Quint typecheck, sampled
safety, bounded verification, positive reachability, and unsafe mutation
counterexamples. Lean must compile and replay in the kernel without admitted
lemmas; the main formal-coverage workflow also includes a full axiom audit.
BarterCore CI covers deterministic reference-transaction negatives.

Do not mark #299 resolved or activate commercial settlement based on this
PR alone. The next implementation branch must integrate a new, still-disabled
source-bound business event and its serialized replay fence in the existing
`CoopSubstrate.Log`, with independent legal/evidence validators.

## 2026-11-08 corrective acceptance record

The first merged proof branch (#340) had **failed Lean elaboration** because
`import Std` did not provide `Finset` in its pinned environment. All
apparently subsequent `sorry` reports followed that failure and were **not
kernel acceptance**. Its dedicated bounded Quint job passed. Its BarterCore
tests reported 43 passes and no test failures, but the formatting gate failed.
The follow-on PR #342 replaces the unsupported finite-set definitions with
explicit two-source boolean-membership state and applies the hosted formatter
patch. This correction does not strengthen legal authority or imply production
admission; exact-head Lean, fresh kernel audit, and Barter formatting must
pass before the repair can be described as verified.
