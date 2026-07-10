# CoopSubstrate

The signed event ledger + capital-account substrate for a member-owned co-op platform:
an append-only, tamper-evident, replayable log of Ed25519-signed canonical events that
every other feature reads from. See `SUBSTRATE.md` (normative) and `docs/handoff.md`
(the build brief); `docs/phase1a_plan.md` / `docs/phase1b_plan.md` / `docs/phase1c_plan.md`
are the completed phase build plans. New here? Start with
[`docs/quickstart.md`](docs/quickstart.md).

**Status: Phases 1A, 1B, and 1C complete** — canonical signed event protocol + append-only
log; membership lifecycle (append-gated state machine) and capital accounts with in-log rule
versioning; throughput/floor compute, the obligation-relationship rail with netting, and the
privacy seams (Aggregate/Proof/JointCompute). Phase 1D (chapter scoping beyond the id,
checkpoints, governance/key structure) is next.

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
- `CoopSubstrate.Membership.Lifecycle` + `Projections.Membership` — the membership state
  machine (invited → probationary → member → departed/retired/floor-exited/deceased) as an
  exhaustive pure transition table, enforced at the **append gate**
  (`Protocol.Validity`): illegal transitions, unregistered parties, stale member keys, and
  malformed economic events are rejected before persistence.
- `CoopSubstrate.Capital` + `Projections.CapitalAccounts` — per-(member, entity) capital
  accounts as a pure fold; accrual rules versioned **in-log** (`AccrualRuleActivated`),
  applied forward-only; redemption schedule structures (FIFO, sinking fund,
  death-to-estate). All parameters placeholder-flagged, awaiting charter declaration.
- `CoopSubstrate.Throughput` + `Floor` — windowed, in-log-versioned throughput compute and
  the participation-floor predicate (`cleared?`), with cure/hardship lifecycle states;
  every verdict a pure function of (log, rule version, caller-supplied instant).
- The **obligation-relationship rail** + `Finance.netting` — dual-signed obligation /
  assignment / discharge events (money movement stays off-platform; no fund-movement event
  type exists) and pure per-denomination pairwise set-off over the open positions.
- `CoopSubstrate.Privacy.{Aggregate, Proof, JointCompute}` — the staged-crypto seams:
  plaintext and trusted-but-auditable backings today, swappable by config with zero caller
  changes; all cross-member aggregates route through them; the public query surface is
  classification-tested (no path returns one member's detail to another).

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
