import Config

config :coop_substrate, event_stores: [CoopSubstrate.EventStore, CoopSubstrate.Records]

# The canonical log stores CoopEventCanonicalV1 bytes VERBATIM (bytea):
# what is signed is what is stored is what is replayed. The serializer is a
# binary pass-through; nothing may re-encode events on the way in or out.
config :coop_substrate, CoopSubstrate.EventStore,
  serializer: CoopSubstrate.Log.Serializer,
  column_data_type: "bytea",
  username: System.get_env("EVENTSTORE_USERNAME", "postgres"),
  password: System.get_env("EVENTSTORE_PASSWORD"),
  hostname: System.get_env("EVENTSTORE_HOST", "localhost"),
  port: 5432,
  pool_size: 5

# Operational records (the evidence quota's charges): never the ledger, so a
# schema of its own in the same database, and Erlang terms rather than
# canonical bytes (docs/architecture/2026-10-20-durable-quota.md).
config :coop_substrate, CoopSubstrate.Records,
  serializer: CoopSubstrate.Records.Serializer,
  column_data_type: "bytea",
  schema: "records",
  username: System.get_env("EVENTSTORE_USERNAME", "postgres"),
  password: System.get_env("EVENTSTORE_PASSWORD"),
  hostname: System.get_env("EVENTSTORE_HOST", "localhost"),
  port: 5432,
  pool_size: 2

import_config "#{config_env()}.exs"
