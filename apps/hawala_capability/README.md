# Hawala capability TEST-host conformance

This app currently contains **only a test adapter**. Its modules compile from
`test/support` in `MIX_ENV=test`; normal builds contain no host, signer, listener,
financial writer or mutation endpoint. No domain application depends on it.

The canonical owner remains `larsbx/hawala-core`. Test fixtures are exact copies
of Lean-generated TSVs at the immutable source commit in
`docs/architecture/fixtures/hawala-cross-authority-v1-pin.json`. Pairing CI
checks every copied byte. Do not change semantics here to make checkout succeed.

```sh
MIX_ENV=test mix test --no-start
MIX_ENV=test mix format --check-formatted
```

The adapter uses three independent worker journals, synced before returning
receipts. Exact replay returns the original local receipt; query current state
separately. Changed payloads, stale writers, missing/mismatched history and
uncertain append fail closed. OTP log auto-repair is disabled. The owner
registry prevents duplicate ownership only within this test VM; production
cross-VM/process fencing and financial append refinement remain open.

Tests compare all 24 fields for 232 formal prefixes and all 72 workflow gates,
reopen workers throughout the corpus, race commit/abort, inject write failure,
kill a worker and check that neither missing acknowledgments nor replay creates
an opposing terminal decision. The fault driver supplies **abstract** messages,
mandates and fences. It is not a signed-envelope, custody or finality verifier,
and no Iroh service is running. The verification Boolean in workflow-gate tests
is an external assumption, never a host assertion of real financial success.

See Hawala's `docs/CROSS_AUTHORITY_HOST_CONFORMANCE.md` for exact guarantees and
limits. G3/D5.5 for an actual financial writer and all deployment gates remain
open. A restricted TEST endpoint/outbox increment now exercises signed local
RPC against the pinned Rust test service. `TestCheckoutOutbox` durably records
signed requests before send; lost replies remain held across restart, replacement
mutations are refused, and fresh signed status queries recover only complete
TEST journal state. `test_reserved` always has `paid=false` and
`financial_authority=false`; no domain checkout or fulfillment calls it.

`SignedTestPort` independently verifies both signing domains, exact request hash,
manifest binding, pinned service and epoch. Rust, Elixir and Node compare the
same golden byte fixture. Pairing CI builds the service at the immutable Hawala
pin and runs a real cross-process lost-reply/restart/status scenario over a
127.0.0.1-only connection. Set `HAWALA_TEST_SERVICE_BIN` to its absolute path to
run that scenario locally; ordinary test runs explicitly exclude it when absent.
CI requires the binary and cannot silently skip it. All four helpers remain
excluded from production builds.

See canonical `docs/TEST_ENDPOINT_ORCHESTRATION.md` for wire bytes, formal
premises, held failures and transport limits. This is a synthetic reservation
harness, with no financial writer, real grant-policy mapping or settlement
proof. Hawala remains the canonical financial owner.
