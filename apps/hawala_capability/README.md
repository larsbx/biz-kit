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
open. There is no synthetic checkout orchestration in this app.
