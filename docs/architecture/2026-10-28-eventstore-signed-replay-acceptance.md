# Direct signed EventStore replay acceptance

This test-only slice continues the formal acceptance merged in #183. It
exercises the currently merged staging `EventReplay` contract. It changes
no runtime module, SQL function, theorem, subscriber or production wiring.

## Boundary exercised

`apps/coop_substrate/test/signed_event_replay_test.exs` uses the existing
`LogCase` canonical signed append path and **unmodified**
`SignedConsumerSource` adapter. The exact checked-in `004_event_cursor.sql`
is installed into the **same disposable test database** as EventStore.
`agent_ops_store` is a test-only dependency of CoopSubstrate, as in the
existing execution-acceptance work in #165; production dependencies stay
unchanged. psql is used only to apply the multi-statement fixture migration.

The cases connect signatures, both-chain prefix audit, real bounded reads,
canonical envelope digest, reviewed derivation and durable SQL commit:

- Declare a real governance key, grant an operator and admit that
  principal's signed offboarding. Replay creates exactly one non-executable
  reconciliation candidate and explicit no-op receipts for reviewed other
  events. Every stored receipt is checked against the accepted envelope's
  sequence, event ID, full-record digest and complete effect bundle.
- Kill a separate replay caller after its bounded page commits and before
  it returns progress to a scheduler. Restart the log appender, use a fresh
  SQL connection, resume at the durable watermark, and check exact duplicate
  registration does not duplicate the candidate or receipt.
- Admit a valid signed event absent from the host's reviewed no-op policy.
  Refuse at that event, preserving the earlier safe prefix; resume only
  after the test host explicitly reviews its policy.
- Refuse a forged signature before canonical admission and demonstrate
  that no operational receipt appears.
- As the disposable database superuser, replace a later stored signature.
  The **real** prefix audit must fail before a new SQL commit. Check existing
  progress remains unchanged; restore the original bytes and resume.
- Refuse a production host before reading host context or accessing SQL.

The focused [workflow](../../.github/workflows/signed-event-replay-acceptance.yml)
checks out and records the literal PR head, pins Elixir 1.19.0 / OTP 27.3.4,
uses PostgreSQL 16, compiles with warnings as errors, checks formatting and
runs these five cases with the two existing signed-source cases under
independent order seeds 1 and 9173. Require successful formal, operational
PostgreSQL, focused signed-replay and Consolidation runs on the proposed
source before integration. An added test is not evidence that it passed;
the associated PR records the exact run IDs and inspected logs.

## Scope retained

The fixture's operator/offboarding events are real signed ledger facts.
The host identity and explicit ignored-type policy are trusted local test
configuration. The fixture grants no execution, backend, payment or business
write authority, starts no subscriber and introduces no checkpoint manager.

PR #165's signed execution/lease acceptance and #166's native persistent
EventStore subscriber remain separate, unmerged work. This harness neither
replaces nor independently accepts their runtime changes. In particular,
choosing or reconciling native EventStore checkpoints and the current
operational cursor is an explicit architectural integration step.

A killed caller after page commit is not a database power-loss, failover,
or in-transaction fault proof. The harness does not establish cryptographic
immutability between audit and read against a privileged storage rewrite,
independently anchored checkpoints, production checkpointer recovery,
all business event derivations, real adapter fencing/idempotency/cancellation,
or old-writer cutover. Those gates remain open under #161/#92.
