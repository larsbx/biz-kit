import Config

config :coop_substrate, CoopSubstrate.EventStore, database: "coop_substrate_eventstore_test"

config :coop_substrate, CoopSubstrate.Records, database: "coop_substrate_eventstore_test"

config :coop_substrate, artifact_dir: "tmp/test_artifacts"
config :coop_substrate, harness_keys_dir: "tmp/test_keys"

config :coop_substrate, :group_buy_clock, CoopSubstrate.GroupBuyClock
config :coop_substrate, :procurement_clock, CoopSubstrate.ProcurementTestClock
