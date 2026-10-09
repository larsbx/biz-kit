# Quickstart

Get from a fresh clone to a signed, verified event in the canonical log in about
five minutes. For what the system *is*, read [`../SUBSTRATE.md`](../SUBSTRATE.md)
(normative spec) and [`handoff.md`](handoff.md) (the build brief).

## Prerequisites

- **Elixir ≥ 1.19** (with OTP; Ed25519 comes from OTP's `:crypto`)
- **Rust** (stable) — the production canonical encoder is a Rustler NIF,
  compiled automatically on first `mix compile`
- **PostgreSQL ≥ 16** running on `localhost:5432`, reachable as user `postgres`
  with no password (defaults live in `config/config.exs`; per-env database
  names in `config/{dev,test}.exs`)

On the project's own dev host these are already satisfied — but note its
Postgres is a hand-started user-local install; see [`machine.md`](machine.md).

## Setup

```sh
mix deps.get
MIX_ENV=dev mix event_store.create
MIX_ENV=dev mix event_store.init
```

Then boot it:

```sh
iex -S mix
```

Booting is itself a test: the application runs a crypto known-answer self-test
(`CoopSubstrate.SelfTest`) at startup and **refuses to boot** if it cannot
reproduce its committed vectors. If `iex -S mix` comes up, signing and
canonical encoding are working.

## Your first event

The substrate stores exactly one thing: Ed25519-signed canonical events in an
append-only, dual-hash-chained log. Paste this into `iex`:

```elixir
alias CoopSubstrate.{Crypto, Log}
alias CoopSubstrate.Protocol.Envelope

# 1. A member keypair (32-byte pubkey + seed)
{pubkey, seed} = Crypto.generate_keypair()
key_id = "k-demo"

# 2. Build a validated envelope for a registered event type
#    (see CoopSubstrate.Protocol.TypeRegistry for the type catalog)
{:ok, envelope} =
  Envelope.new(%{
    chapter_id: "chapter-genesis",
    type: "CharterConstantDeclared",
    payload: %{"name" => "demo_constant", "value" => 42, "note" => "quickstart"},
    signers: [%{role: "author", pubkey: pubkey, key_id: key_id}],
    timestamp_ms: System.system_time(:millisecond)
  })

# 3. Sign the canonical core bytes
{:ok, signed} = Envelope.sign(envelope, key_id, seed)

# 4. Append — the log verifies signatures and assigns chain fields atomically
{:ok, [appended]} = Log.append(signed)
appended.global_seq    # position in the one global log
appended.stream_id     # "chapter-genesis/charter" — derived from type + payload

# 5. Read it back and audit the whole log's hash chains
{:ok, events} = Log.read_stream(appended.stream_id)
:ok = Log.verify_chains()
```

`Log.append/1` rejects anything unsigned, mis-signed, unregistered, or
schema-invalid; `Log.verify_chains/0` re-verifies every stored record's
signatures plus the global and per-stream hash chains, so it returns
`{:error, ...}` if anyone has tampered with the database underneath you —
even as the Postgres superuser.

## Replaying state

State is never stored, only folded from the log. Projections are pure
`init/0` + `handle_event/2` folds (`CoopSubstrate.Projection`):

```elixir
{:ok, stats} = Log.replay(CoopSubstrate.Projections.ChapterStats)
```

Same events in, same state out — deterministically, on any node.

## Running the tests

```sh
mix test                               # creates + initializes the test store itself
cd native/canonical_v1 && cargo test   # independent Rust-side vector verification
```

The Elixir suite includes acceptance tests that forge history as the database
superuser and prove the chains catch it, plus byte-level vector tests locking
the canonical encoding (`test/vectors/`) against both the Rust NIF and the
pure-Elixir reference encoder.

## Where things live

| Path | What |
|---|---|
| `SUBSTRATE.md` | Normative spec — encoding profile, envelope, log, corrections |
| `lib/coop_substrate/canonical.ex` | CoopEventCanonicalV1 encoding (NIF wrapper) |
| `lib/coop_substrate/protocol/` | Envelope V1 + event type registry |
| `lib/coop_substrate/log.ex` | The ONE canonical log: append, read, audit, export, replay |
| `lib/coop_substrate/projections/` | Pure-fold projections |
| `native/canonical_v1/` | Rust encoder (production implementation) |
| `test/vectors/` | Committed byte-level test vectors (frozen) |
| `lib/coop_substrate/membership/` | Membership lifecycle transition table (Phase 1B) |
| `lib/coop_substrate/capital*` | Capital accounts: rules, fold, query API (Phase 1B) |
| `lib/coop_substrate/throughput*`, `floor*` | Throughput/floor compute: rules, fold, queries (Phase 1C) |
| `lib/coop_substrate/finance.ex` | Obligation-rail netting (Phase 1C) |
| `lib/coop_substrate/privacy/` | Aggregate/Proof/JointCompute seams + day-one backings (Phase 1C) |
| `docs/phase1a_plan.md` | Phase 1A build plan (complete; kept as the record of scope) |
| `docs/phase1b_plan.md` | Phase 1B build plan (complete; kept as the record of scope) |
| `docs/phase1c_plan.md` | Phase 1C build plan (complete; kept as the record of scope) |
| `docs/phase1d_plan.md` | Phase 1D build plan (complete; kept as the record of scope) |
| `docs/corpus/` | The normative project corpus (00–13A; `HANDOFF.md` is its index) |
| `docs/handoff.md` | The build brief the plan was cut from |
| `docs/machine.md` | Dev-host snapshot (user-local Postgres, toolchain, ports) |

## Troubleshooting

- **App won't boot, mentions self-test** — the crypto/canonical known-answer
  check failed; your OTP or NIF build is broken. Recompile (`mix deps.compile
  --force && mix compile --force`) and check `rustc --version`.
- **`event_store.create` connection errors** — Postgres isn't on
  `localhost:5432` as `postgres`. Adjust `config/config.exs` (host/user) or
  `config/dev.exs` (database name).
- **NIF compile failure** — install a Rust toolchain (`rustup`); the NIF builds
  via Rustler during `mix compile`.
