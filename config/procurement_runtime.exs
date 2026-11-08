# Dedicated narrow release runtime; does not require unrelated app secrets.
import Config

for store <- [CoopSubstrate.EventStore, CoopSubstrate.Records] do
  config :coop_substrate, store,
    hostname: System.get_env("EVENTSTORE_HOST", "localhost"),
    port: String.to_integer(System.get_env("EVENTSTORE_PORT", "5432")),
    username: System.fetch_env!("EVENTSTORE_USERNAME"),
    password: System.fetch_env!("EVENTSTORE_PASSWORD"),
    database: System.fetch_env!("EVENTSTORE_DATABASE")
end

data = System.fetch_env!("PROCUREMENT_DATA_DIR")
config :coop_substrate, artifact_dir: Path.join(data, "artifacts")
config :coop_substrate, harness_keys_dir: Path.join(data, "keys")
