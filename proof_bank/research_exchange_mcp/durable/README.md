# Durable MCP replay pilot

The optional SQLite backend is a disposable single-slot path for the reviewed
Lean export. The existing stdio launcher and MCP tools handle admission and
receipt reads. An offline operator runs the replay worker. The worker verifies
the selected source profile and replays the exact approved bytes through the
pinned Lean kernel and lean4lean. The worker records a terminal
`dual_checker_passed` or `profile_rejected` receipt. Timeout and inconclusive
replay leave the job queued. Both receipt authority flags are always false.

This pilot remains selected by its existing `durable_database` and
`receipt_key_base64` configuration. The separate
[durable bridge](../../research_exchange_bridge/README.md) uses
`backend: "durable"`, `bridge_config`, and `python_executable` for automatic
controlled replay and guarded terminal acceptance. Its database and receipt
contract are separate from this pilot; mixed configuration fields are refused.

The selected core is unchanged. The admission row maps its worker, generation,
artifact SHA-256 and original times to `Candidate`. The SHA-256 of the
qualified theorem name, source map hash, toolchain lock hash and policy hash
map to the four `Binding` naturals. Discovery also pins the reviewed core
revision and manifest plus the complete checker profile digest. The grant's
epoch lives alongside the candidate because the core candidate has no epoch.

[Admission.lean](formal/Admission.lean) proves successful admission corresponds
to `Reward.submit` and preserves the entire request and current authority
epoch, candidate binding, payouts and escrow. Refusal stutters. Inconclusive
observations, stale epochs and competing terminal outcomes cannot update the
observation in the Lean model. The runtime projects the actual persisted
candidate into a generated Lean example checked with the pinned compiler.
Terminal receipts are observations alongside the submitted core state. The
pilot has zero escrow and invokes no acceptance, reward or refund transition.
SQLite transaction semantics, SHA-256 binding, the trusted local host and
the checker-to-observation adapter remain premises of this correspondence.
The Quint suite is eight finite scenarios.

## Reproduce

Use the lock in the [core package](../../research_exchange/toolchains.lock.json)
and Elixir 1.19.0 / OTP 27.3.4. Fetch the reviewed revision from the repository
root and install the pinned Quint lock into a temporary directory. Run from a
clean committed checkout with the SHA-verified Lean release extracted.

```sh
mcp=proof_bank/research_exchange_mcp
git fetch --no-tags --depth=1 origin "$(python3 -B "$mcp/tools/verify_core_snapshot.py" --print-revision)"
quint_dir="$(mktemp -d)"
cp proof_bank/research_exchange/tooling/quint/package*.json "$quint_dir"
npm ci --prefix "$quint_dir" --ignore-scripts --no-audit --no-fund
bash "$mcp/durable/verify.sh" /path/to/lean-4.35.0-linux \
  "$quint_dir/node_modules/@informalsystems/quint/dist/src/cli.js" "$(mktemp -d)"
```

The command prepares and replays both reviewed exports and records the Git
commit and tree, source identity, Quint scenarios, real MCP acceptance,
checker receipts and generated Lean check. The acceptance suite covers
wrong target and source, a valid export for the alternate target, grant
revocation between replay and commit, concurrent real replays, a simulated
checker timeout followed by real replay, and actual worker process exits
before and after SQLite commit. It also checks response MACs after relaunch.

## Disposable operation

Prepare the profile with the existing `adapter_pilot.prepare_fixture`
command. In an operator-owned directory with restrictive permissions, set
`RESEARCH_EXCHANGE_TOKEN` to a high-entropy URL-safe token and provision a
new database. Set `RESEARCH_EXCHANGE_CONFIG` to an operator-owned JSON file
with `durable_database` (absolute path) and `receipt_key_base64` (independent
32-byte secret encoded as Base64). Keep that receipt key stable across
restarts.

```sh
python3 -B "$mcp/durable/runtime.py" --db "$db" provision --profile "$profile"
elixir "$mcp/bin/stdio.exs"
python3 -B "$mcp/durable/runtime.py" --db "$db" replay --lean-root "$lean_root"
```

The client discovers the pinned target and submits the UTF-8 export and
its digest. `verification_request` queues the returned submission ID, and
`receipt_get` reads the returned job ID. Retry the worker after transient
failure. An offline `revoke` advances the sole grant's epoch and prevents
pending work from committing. Use a new disposable database for a new
candidate. The pilot assumes trusted operator control of the database,
configuration and worker. It covers one fixed Lean fixture under the reviewed
profile. General Lean, mathlib and Quint execution, deployment and issuance
are outside this pilot.
