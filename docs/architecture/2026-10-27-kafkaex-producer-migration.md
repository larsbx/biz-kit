# Eatsbot KafkaEx 1.1.2 producer migration

## Scope

Replace the removed 0.x producer structs and implicit producer call with the
supported explicit-client API. Preserve `EatsbotCore.Kafka.produce/3`, partition
0, leader acknowledgments, binary values, core map-to-JSON encoding, and the
original ignored-options behavior. Do not add an adapter retry loop or claim
exactly-once delivery.

The extension now owns a named produce-only client under its supervisor. Its
`start_link/1` returns the extension supervisor PID, rather than the worker PID.
The optional dependency remains `runtime: false`; the extension starts the
client only when enabled. SSL is an explicit application dependency for TLS
broker configurations. Broker/security defaults still come from KafkaEx config.

## Upstream contracts inspected before implementation

KafkaEx tag `v1.1.2`, commit `2e9ce8bb0331af06f9e53398793e09f1c469c7b8`:

- [Migration guide](https://github.com/kafkaex/kafka_ex/blob/v1.1.2/UPGRADING.md):
  `KafkaEx.API` replaces producer functions on `KafkaEx`; a client must be supplied.
- [API](https://github.com/kafkaex/kafka_ex/blob/v1.1.2/lib/kafka_ex/api.ex):
  `produce(client, topic, partition, [%{value: binary}], acks: 1)` returns
  `{:ok, %KafkaEx.Messages.RecordMetadata{}}` or `{:error, reason}`. The API
  normalizes structured client errors to their error atom. Its default acks is
  -1, so explicitly passing 1 is required to retain the old driver behavior.
- [Wire builder](https://github.com/kafkaex/kafka_ex/blob/v1.1.2/lib/kafka_ex/protocol/kayrock/produce/request_helpers.ex):
  maps become Kayrock records; values are binary payloads, not implicitly JSON.
- [Metadata](https://github.com/kafkaex/kafka_ex/blob/v1.1.2/lib/kafka_ex/messages/record_metadata.ex):
  acknowledged batches carry a base offset; `acks: 0` carries nil and is not a
  broker acknowledgment. The adapter requires matching topic/partition and a
  nonnegative integer offset before returning `:ok`.
- [Client retry loop](https://github.com/kafkaex/kafka_ex/blob/v1.1.2/lib/kafka_ex/client/client.ex)
  and [retry classification](https://github.com/kafkaex/kafka_ex/blob/v1.1.2/lib/kafka_ex/support/retry.ex):
  at most three attempts for leadership errors, refreshing metadata. Broker
  timeouts and transport failures are not safe produce retries. The adapter
  preserves error tuples, converts client exits to error tuples, and never
  resends on its own. A timeout still leaves delivery uncertain.
- `KafkaEx.API.child_spec/1` merges application defaults and supervises the
  explicit named client. `consumer_group: :no_consumer_group` marks it produce-only.

Invalid direct-driver payloads/topics fail before contacting the client. The
core's existing `Jason.encode!` exception behavior for unencodable maps is
unchanged and covered by a regression.

## Acceptance

Run with the locked dependencies and Elixir 1.19 / OTP 27:

```sh
MIX_ENV=test mix deps.get --check-locked
MIX_ENV=test mix compile --warnings-as-errors
(cd apps/eatsbot_extension_kafka && MIX_ENV=test mix format --check-formatted)
(cd apps/eatsbot_extension_kafka && MIX_ENV=test mix test --no-start)
# Isolated Kafka 3.8.1 on localhost:19092, auto-create enabled, one partition,
# default ~1 MiB message limit. No production broker or credentials are used.
(cd apps/eatsbot_extension_kafka && KAFKA_PORT=19092 MIX_ENV=test mix test --no-start --include kafka_integration)
```

The extension test task is run from its app directory: umbrella-level test
aliases also invoke unrelated application database setup.

- Adapter/API regression cases cover binary values, empty values, offset zero,
  JSON, malformed inputs, acknowledgment mismatches, broker errors, stopped
  clients, and absence of adapter resends.
- Independent TCP fixtures use real KafkaEx client callbacks, network requests,
  Kayrock encoding and response parsing. They verify leader recovery, the
  three-attempt limit, and one send for timeout/authorization failures.
- Real Kafka acceptance checks exact fetched bytes/JSON, offsets with no extra
  records, oversized-record broker rejection, continued operation after refusal,
  and producer supervision/restart.
- `.github/workflows/kafka-producer.yml` supplies an isolated Apache Kafka 3.8.1
  service, locked resolution, strict umbrella compilation and all Kafka cases.
- Existing full-lock audit, Eatsbot tests and production release-smoke workflows
  remain acceptance requirements on the exact PR revision. A written workflow
  or a successful resolver/audit is not evidence that runtime tests passed.

Only KafkaEx, Kayrock and CRC32C lock entries change. Bandit 1.14.0, Ash 3.37.2,
AshPostgres 2.15.2, AshSQL 0.8.4 and JOSE 1.11.13 remain accepted security versions.
PR #145's other updates remain separate acceptance obligations. Reconciliation
must preserve those security versions and rerun checks on the resulting head.
