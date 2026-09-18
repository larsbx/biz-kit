import Config

config :dispatch,
  ecto_repos: [Dispatch.Repo],
  environment: config_env(),
  generators: [timestamp_type: :utc_datetime_usec]

# Section 19.2: UTC RFC 3339 with millisecond precision at API boundaries and
# timestamptz in PostgreSQL.
config :dispatch, Dispatch.Repo,
  migration_primary_key: [name: :id, type: :uuid],
  migration_timestamps: [type: :utc_datetime_usec]

config :dispatch, DispatchWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: DispatchWeb.ErrorJSON], layout: false],
  pubsub_server: Dispatch.PubSub

# Section 32: structured JSON logs carrying correlation IDs.
config :logger, :default_formatter,
  format: {Dispatch.LogFormatter, :format},
  metadata: [:request_id, :correlation_id, :tenant_id]

config :phoenix, :json_library, Jason

# Section 21.3: one queue, FIFO by insertion. Section 27.6 forbids priority
# queues, so a single queue is the structural guarantee rather than a
# convention that a later job definition could quietly break.
config :dispatch, Oban,
  repo: Dispatch.Repo,
  queues: [operations: 20],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]

import_config "#{config_env()}.exs"
