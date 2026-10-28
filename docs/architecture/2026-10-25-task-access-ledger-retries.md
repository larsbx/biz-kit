# Task access admission and exact-envelope retry repair

## Diagnosis on main

Main `afe64b3df42a51edb1202627d2c83bceeb682856` includes marketplace
redelivery (#119) and event-driven Iroh gossip (#120). Its pinned
Elixir 1.19.0 / OTP 27.3.4 / PostgreSQL 16 Consolidation run
[40200383540](https://github.com/larsbx/biz-kit/actions/runs/40200383540),
job `121190112360`, reproduces both failures in
`CoopSubstrate.TaskAgentRunIntentsTest`: 584 tests, 20 properties,
one doctest, two failures. TaskCore and AgentCore pass before the ledger
step fails; orchestration is skipped, not validated by that baseline run.

1. **Unauthorized signer fixture:** `signed_event/4` requires
   `Envelope.new/1` to succeed. A TaskAccessGrantedV1 declares governance,
   but the fixture supplied a suggester-role signer. The builder correctly
   returned `roles_mismatch`, so the test crashed before reaching its
   ledger-refusal assertion. This is a fixture defect, not evidence that
   authorization should accept the envelope.
2. **Missing retry tracking:** TaskCore.Access retained only a mutable
   permission projection, while CoopSubstrate.Tasks.duplicate/2 consults
   accepted command envelopes. Access grants/revokes were absent from that
   lookup. A second submission of the identical signed grant therefore
   reached admission and correctly failed `task_access_grant_already_recorded`
   instead of returning the historical acceptance. This is an implementation
   omission in the host's retry integration, not a reason to relax admission.

The source paths and pinned main run establish these causes without an
assumption about shared fixtures, database residue or toolchain drift.

## Correction and retained boundaries

TaskCore.Access now retains accepted grant/revoke envelopes in
`task_access_commands`, separately from `task_access_grants`. The ledger
includes that map in its existing singleton-command retry lookup. Full
signature/role verification and append guards still run first. Only equal
signed cores **and** equal signature sets acknowledge the prior accepted
envelope. Conflicting reuse returns `task_command_id_conflict`.

Acknowledgment returns history; it does not fold the grant again, append
an event, advance the ledger, or reactivate a revoked permission. Replay
rebuilds the command map from the canonical ledger, including after restart;
there is no database migration or wire-format change. Multi-event batches
retain existing all-or-nothing admission and do not acquire partial-retry
semantics. TaskCore's duplicate-grant refusal remains unchanged.

The corrected signer fixture claims governance using the actual suggester
key. Its envelope is cryptographically valid but admission must reject the
undeclared governance key specifically. Additional coverage preserves the
constructor's role refusal and verifies that a genuinely signed, wrong-role
wire struct is also refused by append.

Regression coverage includes read and execute retries, changed signed
content under an accepted ID, invalid signatures, mixed old/new atomic
batches, restart recovery, grant/revoke retries after revocation, unchanged
ledger heads/projections, chain integrity, and immutable command receipts
through principal offboarding. Existing assertions remain in force.

## Reproducible validation

Use a disposable PostgreSQL 16 instance: the common-ledger test alias drops
and recreates its configured test database. The authoritative integration
commands are the repository's existing Consolidation workflow, with locked
umbrella dependencies and its pinned BEAM runtime:

```sh
export MIX_ENV=test
export EVENTSTORE_USERNAME=postgres EVENTSTORE_PASSWORD=postgres
export SPRUCE_GOOSE_TEST_DATABASE_PASSWORD=postgres PGPASSWORD=postgres
mix deps.get --check-locked
mix compile --warnings-as-errors
(cd apps/task_core && mix test)
(cd apps/agent_core && mix test)
(cd apps/coop_substrate && mix test test/task_agent_run_intents_test.exs)
(cd apps/coop_substrate && mix test)
(cd apps/spruce_goose && mix ecto.create && mix ecto.migrate && mix test)
```

The dependency-free portable TaskCore package also runs independently:
copy `apps/task_core` outside the umbrella, then run
`MIX_ENV=test mix compile --warnings-as-errors && mix test`. On the pinned
Elixir 1.19.0 / OTP 27.3.4 runtime this repair passes **102 tests** locally.
Hosted acceptance and final exact-revision results are recorded on the PR.
Marketplace source is unchanged; its current merged revision remains the
base, and the Federation discovery security suite supplies its separate
network acceptance evidence.
