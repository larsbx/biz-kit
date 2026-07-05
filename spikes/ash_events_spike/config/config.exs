import Config

config :ash_events_spike, ash_domains: [AshEventsSpike.Notes]
config :ash_events_spike, ecto_repos: [AshEventsSpike.Repo]

config :ash_events_spike, AshEventsSpike.Repo,
  username: "postgres",
  hostname: "localhost",
  port: 5432,
  database: "ash_events_spike_dev",
  pool_size: 5

config :ash, disable_async?: true
