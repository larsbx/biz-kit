# Durable staging reference receiver

This experiment receives exact admission-bound operational requests in a
separate Python process and retains identities/fences in SQLite. It starts
no workload and implements no production agent-provider adapter.

The trusted host uses `CoopSubstrate.AgentBackendRequest` to bind the real
Log admission receipt and approved plan, pins the receiver's store ID, and
uses private stdio. No lease token, business credential or arbitrary command
belongs in a request.

```sh
python3 -m unittest discover -s experiments/agent_backend_receiver \
  -p 'test_*.py' -v
```

Initialize a dedicated private directory once, retaining the returned store
identity:

```sh
mkdir -m 700 /tmp/bizkit-agent-receiver-demo
python3 experiments/agent_backend_receiver/receiver.py init \
  --db /tmp/bizkit-agent-receiver-demo/receiver.sqlite3
```

Send a closed host-generated JSON request:

```sh
python3 experiments/agent_backend_receiver/receiver.py request \
  --db /tmp/bizkit-agent-receiver-demo/receiver.sqlite3 < REQUEST.json
```

Every operation names the pinned store. Request handling never initializes
a missing file. `create` retains one exact request identity; `lookup` reports
known state or non-final `unknown`; `fence` commits a permanent tombstone,
including before any create. A fence acknowledgement establishes refusal of
later creates at this receiver, not physical termination or atomicity with a
separate signed ledger.

See the [full contract and acceptance boundary](../../docs/architecture/2026-11-16-agentcore-durable-backend-receiver.md).
