# Local durable MCP execution bridge

This opt-in package connects the four existing MCP tools to SQLite and the
reviewed Lean export checker and the separately provisioned bounded Lean source
profile. It is a standalone local acceptance pilot, with no
automatic Biz-kit startup or network listener. The default MCP backend remains
memory-only. See the [proof and acceptance contract](../../docs/proof-bank/research-exchange/DURABLE_MCP_BRIDGE.md)
for the exact representation theorem, implemented behavior and remaining premises.

## Verify the complete bridge

Use the unchanged core toolchain lock: Lean 4.35.0, Quint 0.33.1, Apalache 0.62.4,
JRE 21.0.13+9, Node 24.22.1, npm 11.9.0, Python 3.12, plus exact Elixir 1.19.0 /
OTP 27.3.4. Follow the [core bootstrap instructions](../research_exchange/README.md)
to obtain the checked distributions. Prepare the pinned mathlib import bundle
with the [source-profile instructions](../../docs/proof-bank/research-exchange/BOUNDED_LEAN_SOURCE.md).
Run from a clean repository root:

```bash
snapshot_tool=proof_bank/research_exchange_mcp/tools/verify_core_snapshot.py
git fetch --no-tags --depth=1 origin "$(python3 -B "$snapshot_tool" --print-revision)"
python3 -B "$snapshot_tool" --require-clean
python3 -B -m unittest discover -s proof_bank/research_exchange_bridge/tools -p 'test_*.py' -v

BRIDGE_TOOLS=/absolute/path/to/research-exchange-tools
SOURCE_IMPORTS=/absolute/path/to/exchange-source-imports
python3 -B proof_bank/research_exchange_bridge/tools/verify.py \
  --expected-revision "$(git rev-parse HEAD)" \
  --lean-root "$BRIDGE_TOOLS/lean-4.35.0-linux" \
  --quint-cli "$BRIDGE_TOOLS/quint/node_modules/@informalsystems/quint/dist/src/cli.js" \
  --java-bin "$BRIDGE_TOOLS/jdk-21.0.13+9-jre/bin/java" \
  --quint-home "$BRIDGE_TOOLS/quint-home" \
  --elixir "$(command -v elixir)" \
  --source-imports "$SOURCE_IMPORTS" \
  --output-dir /absolute/path/to/new-bridge-evidence
```

All six stages are required: cold proofs, Quint models, reviewed export fixture
preparation, export runtime acceptance, source runtime acceptance, and compiled
representation conformance. The output directory must be new or empty. The
receipt records source identity before and after execution and hashes the
evidence. Cold proof builds occur in isolated source copies; generated build
workspaces are not evidence artifacts. The separate complete core workflow and
MCP regression workflow are also required at the proposed integration revision.

The runtime suite drives the actual Elixir subprocess, private Python channel,
SQLite transactions and real pinned checkers. It includes accepted/rejected
outcomes, shared-store authorization, pending-work recovery, lost-response
retries, revocation/regrant after checking, competing prepared workers, and
process exits on both sides of commit. Secret configuration, raw tokens and
database files are not copied into the evidence. The conformance stage compares
generated cases and actual committed database wire records from both profiles
with compiled Lean, including their persisted post-states and effects. Each
profile must supply actual committed observations; a passing test summary alone
does not satisfy that requirement.

The source stage requires all seven registered cases with zero skips, including
real MCP initialization, discovery, source submission, asynchronous admission,
operator-selected compilation and dual replay, restart and receipt retrieval.
It retains the real worker SIGINT/recovery control and records the pinned import
and runtime identities before and after the suite. Missing prerequisites fail
acceptance. The aggregate source-after inventory runs after both profiles and
conformance.

## Start a disposable local instance

First prepare the reviewed export fixture using the core's existing command.
The generated instance directory must not already exist:

```bash
BRIDGE_RUN="$(mktemp -d)"
PYTHONPATH="$PWD/proof_bank/research_exchange" python3 -B -m adapter_pilot.prepare_fixture \
  --lean-root "$BRIDGE_TOOLS/lean-4.35.0-linux" \
  --output-dir "$BRIDGE_RUN/fixtures"
python3 -I -B proof_bank/research_exchange_bridge/provision.py \
  --destination "$BRIDGE_RUN/instance" \
  --profile "$BRIDGE_RUN/fixtures/profile.json" \
  --lean-root "$BRIDGE_TOOLS/lean-4.35.0-linux"

RESEARCH_EXCHANGE_CONFIG="$BRIDGE_RUN/instance/mcp.json" \
RESEARCH_EXCHANGE_TOKEN="$(cat "$BRIDGE_RUN/instance/contributor.token")" \
  elixir proof_bank/research_exchange_mcp/bin/stdio.exs
```

Provisioning creates a protected directory, database, configuration and one
short-lived local contributor credential. It prints paths and catalog metadata,
not credentials. Restart does not reprovision grants or erase revocations. Token,
MAC key, configuration, database and host privileges belong to the trusted local
operator; the agent receives only the configured stdio channel.

The outer configuration contains exactly:

```json
{
  "backend": "durable",
  "bridge_config": "/absolute/path/to/instance/bridge.json",
  "python_executable": "/absolute/path/to/python3"
}
```

The existing [disposable replay pilot](../research_exchange_mcp/durable/README.md)
continues to use its separate `durable_database` and `receipt_key_base64`
configuration and offline operator worker. Its observation receipts keep both
authority flags false. These profiles have separate database and receipt
contracts; configuration fields from the two profiles cannot be combined.

Initialize MCP as documented in the [front-end guide](../research_exchange_mcp/README.md).
Discover the catalog, submit the UTF-8 contents of `fixtures/expected.export` with
its SHA-256 and the catalog's exact fields, then request verification using the
returned submission ID. The target is
`ResearchExchange.Adapter.expected_fixture`. Poll `receipt_get` with the returned
job ID for the terminal receipt. The queued acknowledgement is not acceptance.

For this reviewed-export instance, `mathematical_acceptance: true` requires
successful dual replay of the exact reviewed export followed by the guarded
durable commit. The receipt names that scope and retains checker outputs.
The separately provisioned source library accepts only the documented term
fragment for `submitted : Nat.Prime 2`, with its own `bounded-lean-source-v1`
receipt scope and explicit operator worker. `credit_issuance` remains false for
both profiles. Arbitrary mathlib source and Quint programs are outside these
profiles.

## Recovery and trusted administration

Pending dispatch survives restart. A completed operation keeps its original
request receipt, and `receipt_get` returns the latest stored result. Authorization
is checked again before reads and retries. Conflicting reuse of a request ID
fails. One submission can acquire only one job.

Inconclusive checking leaves the represented state and fixture effect unchanged
and pauses dispatch. After repairing the local checker, an operator can retry:

```bash
python3 -I -B proof_bank/research_exchange_bridge/worker.py \
  --config /absolute/path/to/instance/bridge.json \
  --job-id RETURNED_JOB_ID \
  --retry-inconclusive
```

`Store.set_grant_enabled` and `Store.set_verifier_enabled` are trusted offline
administration methods, not MCP tools. Revoke/regrant increments the relevant
epoch. An old prepared result is refused even if the grant is enabled again.
A revoked requester job requires a fresh admission; operator retry does not
bypass its original grant binding.

Trusted test configuration can select `test_failpoint: before_commit` or
`after_commit`, optionally restricted by `test_job_id`. The worker then calls
`os._exit(86)` or `os._exit(87)` at the actual transaction boundary. A
`test_pause_after_check` path and optional `test_pause_job_id` expose a bounded
post-check barrier for revocation/race tests. These are operator test settings;
MCP arguments cannot select them.

The implementation guarantees one durable terminal effect per job under its
local transaction premise. It can perform duplicate checking during races and
recovery. It has no physical metering, stop acknowledgement, global budget,
distributed storage or external settlement guarantee.
