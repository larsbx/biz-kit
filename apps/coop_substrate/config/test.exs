import Config

config :coop_substrate, CoopSubstrate.EventStore,
  database: "coop_substrate_eventstore_test"

config :coop_substrate, artifact_dir: "tmp/test_artifacts"
config :coop_substrate, harness_keys_dir: "tmp/test_keys"
