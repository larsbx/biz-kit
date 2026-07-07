# CoopSubstrate

The signed event ledger + capital-account substrate for a member-owned co-op platform:
an append-only, tamper-evident, replayable log of Ed25519-signed canonical events that
every other feature reads from. See `SUBSTRATE.md` (normative) and `docs/handoff.md`
(the build brief); `docs/phase1a_plan.md` is the completed Phase 1A build plan. New here?
Start with [`docs/quickstart.md`](docs/quickstart.md).

**Status: Phase 1A complete** — canonical signed event protocol + append-only log.
Phase 1B (membership lifecycle + capital-account fold) is next.

## What exists

- `CoopEventCanonicalV1` — a frozen deterministic encoding profile (strict CBOR subset),
  implemented twice (Rust NIF, production; pure-Elixir reference, test) and locked with
  committed byte-level test vectors (`test/vectors/`).
- `CoopSubstrate.Crypto` + boot-gating self-test — Ed25519 via OTP; the app refuses to
  boot if it cannot reproduce its known-answer vectors.
- `CoopSubstrate.Protocol.Envelope` — Event Envelope V1: a signed core (multi-signer,
  role-tagged) plus log-assigned dual chain fields; `event_hash` covers the full record.
- `CoopSubstrate.Log` — the ONE canonical log, on Commanded's `eventstore` (Postgres):
  verify-on-append, atomic batches, global + per-stream hash chains, tamper audit
  (`verify_chains/0`), as-of reads, per-stream export with independent verification.
- `CoopSubstrate.Projection` + `Log.replay/2` — deterministic pure-fold replay.

## Running

Requires Elixir ≥ 1.19, Rust (for the NIF), PostgreSQL ≥ 16.

```sh
mix deps.get
MIX_ENV=dev mix event_store.create && MIX_ENV=dev mix event_store.init
iex -S mix          # boots only if the crypto self-test passes

mix test            # creates/initializes the test store, runs the full suite
cd native/canonical_v1 && cargo test   # independent Rust-side vector verification
```

Database credentials live in `config/{dev,test}.exs`. The dev host's
environment (user-local Postgres, toolchain, network) is documented in
[`docs/machine.md`](docs/machine.md).
