# Verify a submitted Lean proof term

The local `lean-source-prime-two-v1` library accepts a Lean proof term for
`submitted : Nat.Prime 2`. Its environment is Lean 4.35.0 from the existing
research-exchange toolchain lock and mathlib commit
`56a005855ea17e0b0958f73ec801ae140b0a1679`. The mathlib checkout's committed
Lake manifest pins its transitive package revisions.

The accepted fragment uses `Nat.prime_two`, `id`, parentheses and horizontal
ASCII whitespace. For example, submit `id (Nat.prime_two)`. The materializer
inserts the exact bytes inside the fixed theorem declaration. Its grammar
excludes imports, tactics, comments, syntax extensions and executable commands.
Lean checks the term against the statement. An axiom audit permits only `Classical.choice`,
`Quot.sound` and `propext`. Both existing checkers replay the same exported closure.

## Reproduce

Run from the repository root on Linux, with Python 3.12 and util-linux
`prlimit`. Set `EXCHANGE_LEAN_ROOT` to the verified toolchain directory
produced by `proof_bank/research_exchange/tools/bootstrap.py`. Use a fresh
mathlib checkout and a new destination for each preparation.

```sh
export PATH="$EXCHANGE_LEAN_ROOT/bin:$PATH"
export EXCHANGE_SOURCE_IMPORTS="$PWD/exchange-source-imports"
git clone --branch v4.35.0 --depth 1 https://github.com/leanprover-community/mathlib4.git exchange-mathlib
git -C exchange-mathlib checkout --detach 56a005855ea17e0b0958f73ec801ae140b0a1679
(cd exchange-mathlib && lake build +Mathlib.Data.Nat.Prime.Defs)
python3 -B proof_bank/research_exchange_bridge/tools/prepare_source_imports.py \
  exchange-mathlib "$EXCHANGE_SOURCE_IMPORTS"
PYTHONPATH=proof_bank python3 -B -m unittest research_exchange_bridge.tests.test_source -v
python3 -B proof_bank/research_exchange_bridge/tools/check_bridge_proofs.py \
  --lean-root "$EXCHANGE_LEAN_ROOT" --output-dir /tmp/exchange-source-proofs
```

For a disposable bridge, run `tools/provision_source.py` with the operator's
`--config`, `--source-imports`, a fresh `--token-file` and `--principal`.
Use the returned library metadata in `proof_submit`, with the term as the
`artifact`, its SHA-256 as `artifact_sha256`, and `submitted` as the target.
Call `verification_request` with the submission ID. The operator selects that
job with `worker.py --config … --job-id … --source-imports …`. The stdio
background worker processes reviewed exports only.

The provisioner fingerprints the import bundle and the pinned Lean distribution.
Use a trusted, clean build to prepare the import bundle. Provisioning trusts
the operator's association of those compiled bytes with the verified checkouts.
Keep the bundle and toolchain read-only to contributors. The worker checks their
identities before and after checking. Host integrity, compiler/exporter
correctness, checker correctness and SHA-256 collision resistance are premises.

The worker uses a private temporary directory and a fixed executable sequence.
Source size, token count, nesting, Lean heartbeats and recursion, address space,
CPU time, wall time and per-file output are bounded. Timeout kills the child
process group. A hard worker interruption can leave scratch files or a bounded
child until its resource limit or natural exit. A later worker starts in a
fresh directory and rechecks the immutable source. After an inconclusive attempt,
use `--retry-inconclusive` with the same job. This restricted grammar and
resource boundary is designed for a trusted local host.

## Read the receipt

The durable input digest identifies the submitted term. The accepted receipt's
`controlled_check` binds that digest to the materialized module, target,
statement, library revision, environment, policy, axiom list and closure digest.
The existing durable commit revalidates the bytes, profile, authority epochs
and row version in one transaction. The reviewed-export scope and receipt shape
are preserved. Source receipts use `bounded-lean-source-v1`; successful source
receipts assert mathematical acceptance and every receipt keeps
`credit_issuance` false. Failed stages leave the modeled row and effect set
unchanged.

Quint execution would need a pinned engine and dependency resolver, exact model
and property identities, bounded exploration parameters, and distinct outcomes
for complete exploration, counterexample and incomplete runs. A replayable trace
and checker identity would need to bind to those same inputs before admission.

UTCP exposure would need a versioned tool schema and capability discovery,
authenticated per-profile grants, binding-preserving request and response
mapping, idempotency, and equivalent receipt verification and cancellation
semantics. Both extensions are future work.
