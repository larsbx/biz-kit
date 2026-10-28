# EventStore formal acceptance record — 2026-10-28

This records source and CI inspection after PRs #168–#170 merged. It grants
no production execution, business-write, payment or federation authority.

## Reconciled source and historical evidence

| Change | Final source head | Observed acceptance |
| --- | --- | --- |
| #168 formal repair | `14d27a92794d03392bc5f21a7e8acc6d91aaf9bb` | [Formal run 40690157567](https://github.com/larsbx/biz-kit/actions/runs/40690157567), [Consolidation 40690157617](https://github.com/larsbx/biz-kit/actions/runs/40690157617), [PostgreSQL 40690157493](https://github.com/larsbx/biz-kit/actions/runs/40690157493): success |
| #169 cursor assertions | `df969082c1e14f541897aaa2cd421a9147914b19` | [PostgreSQL 40641053661](https://github.com/larsbx/biz-kit/actions/runs/40641053661), [Consolidation 40641053748](https://github.com/larsbx/biz-kit/actions/runs/40641053748): success |
| #170 staging replay | `6c211b66bd6a5ae1f15e3cbe15ecb4ea236bff70` | [PostgreSQL 40641241023](https://github.com/larsbx/biz-kit/actions/runs/40641241023), [Consolidation 40641240961](https://github.com/larsbx/biz-kit/actions/runs/40641240961): success |

These historical PR jobs used GitHub's synthetic merge checkout. In
particular #168 checked `5534bd7448b3f7664f152f92f9dff5fea4cfa9c7`
(head `14d27a9` merged with #174's `25f0406` baseline). #170's PostgreSQL
job checked `47065fc`, merging its head with `736b5a1`. A run associated
with a head SHA is not automatically a literal checkout of that SHA.

#168's earlier `46b9662` run failed downloading Lean before elaboration.
Later execution exposed genuine proof issues: indexed-constructor case
arguments, unfolding `acknowledge` in a proof, and an unnecessary simplifier
argument. Commit `14d27a9` fixes these proof terms without changing theorem
statements. The final logs identify Lean 4.35.0 commit
`eb6cafb7290e8bd5f2937522d8d804f58f02bafc`, compilation of all three modules,
bundled `leanchecker`, and an audit of 46 declarations **defined in the
BizKitEventProofs module**. That historical audit did not separately select
the definitions in BizKitBundles and BizKitLeases.

The final Quint log contains four passing sampled/bounded safety checks,
nine reachable-state witnesses, and real invariant violations for all
three deliberate bugs. This is finite evidence, not unbounded runtime or
cryptographic acceptance. #174's formatting is preserved; the only later
changes to those three cursor files are #169's two corrected assertions.

## Reproducible verification changes

- Install official Lean 4.35.0 Linux x86_64 directly from GitHub, with
  committed SHA-256 `7289597a44543246c9227b8cae501767e095ce17f6d448b95fc4a8dc97268f6d`.
  This digest was obtained from the official release API and independently
  matched against the downloaded archive. Verify cold downloads and every
  restored archive before extraction; never disable TLS or trust cached
  project oleans.
- Rebuild, then `leanchecker --fresh --verbose BizKitEventProofs` replays
  the complete imported environment in Lean's kernel. Audit all three
  defining modules against only `propext,Classical.choice,Quot.sound`, using
  axiom-audit commit `46024e005996495c65ef609368e11ab39c4222e3`.
- Record and check out literal PR heads for formal and PostgreSQL checks.
  Changes to formal sources and cursor/replay contracts trigger both lanes;
  require their results together with Consolidation on that revision.

## Contract correspondence and limits

| Formal requirement | Concrete implementation | Acceptance coverage / boundary |
| --- | --- | --- |
| Lean index n maps to sequence n+1; cursor is completed prefix length | `EventCursor.watermark/3` returns `{:ok, integer}`; SQL requires `p_seq = last_seq + 1` | Cursor integration assertions, SQL gap rejection; no cursor-only acknowledgement API |
| Atomic complete bundle + processed receipt + cursor | `commit_event_bundle` locks the home/consumer cursor, inserts receipt and every effect, then advances under the observed sequence | Multi-effect/no-op/duplicate tests; a conflicting effect insert rolls back the receipt and cursor; two independent connections race |
| Duplicate registration is idempotent | Existing positions must match event ID, digest and immutable bundle | Conflicting identity/bundle rejected; exact duplicate returns existing watermark |
| Crash preserves committed facts | One SQL transaction per event; replay resumes from durable watermark | Partial-write rollback and bounded restart/resume tested; named-volume lane checks storage survival but its restart marker is not an EventStore replay crash test |
| Authenticated immutable event and complete derivation are assumptions | `SignedConsumerSource.verified_head/0` audits both chains; bounded reads, canonical digest; reviewed `EventEffects` mapping | Separate real signed LogCase and synthetic-source PostgreSQL replay fixtures; no single cryptographic end-to-end replay fixture yet |
| Per-home non-authority | Home/consumer compound keys; trusted staging host and explicit reviewed no-op types | Production host rejected; unknown event types halt; registered rows are non-executable candidates |

`read_page/2` is a trusted-host adapter call, not a capability bound to a
previous audit: its API does not independently enforce that the caller
has audited that head. `EventReplay.drain/3` performs the required ordering.
It validates gaps/reordering before page writes, then commits **per event**;
an unknown later type may leave an earlier safe prefix committed. No claim
of page-wide atomicity is made.

Remaining production gates include independently anchored checkpoints and
storage-rewrite trust, multi-process crash injection at transaction/ack
boundaries, cryptographic end-to-end replay, independently accepted
checkpointer recovery, current grant/profile/consent checks at execution,
backend handle recovery and external effect deduplication, old-writer
fencing and separate release/cutover approval. The O(history) prefix audit
is still a staging limitation. See [#161](https://github.com/larsbx/biz-kit/issues/161).

## Infrastructure prerequisites

The full new gate requires a Linux x86_64 runner able to execute the
release binaries and discover their executable paths, zstd/tar, TLS access
to official GitHub assets or an intact verified archive cache, Git access
to the pinned audit commit, and Quint's evaluator plus Apalache/Java.
PostgreSQL/Postgrex and genuine signed-ledger tests require their CI
database and Erlang/Elixir environment. Download, startup and missing-tool
failures are infrastructure evidence; they never count as proof success.
