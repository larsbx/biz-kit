import Config

config :coop_substrate, CoopSubstrate.EventStore,
  database: "coop_substrate_eventstore_dev"

config :coop_substrate, CoopSubstrate.Records, database: "coop_substrate_eventstore_dev"
