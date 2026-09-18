import Config

# The seven domains of Section 21.2. Registering them here is what lets Ash
# resolve a resource to its domain and check code interfaces at compile time.
config :dispatch,
  ash_domains: [
    Dispatch.Accounts,
    Dispatch.Fleet,
    Dispatch.Operations,
    Dispatch.Communications,
    Dispatch.Identity,
    Dispatch.Audit,
    Dispatch.Integrations
  ],
  ecto_repos: [Dispatch.Repo],
  environment: config_env(),
  generators: [timestamp_type: :utc_datetime_usec]

# Section 19.2: UTC RFC 3339 with millisecond precision at API boundaries and
# timestamptz in PostgreSQL.
config :dispatch, Dispatch.Repo,
  migration_primary_key: [name: :id, type: :uuid],
  migration_timestamps: [type: :utc_datetime_usec],
  # Section 28.2: PostGIS is canonical, and `geography` columns need the Geo
  # extension registered with Postgrex or every position write fails at the
  # driver.
  types: Dispatch.PostgresTypes

config :dispatch, DispatchWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: DispatchWeb.ErrorJSON], layout: false],
  pubsub_server: Dispatch.PubSub

# Section 32: structured JSON logs carrying correlation IDs.
config :logger, :default_formatter,
  format: {Dispatch.LogFormatter, :format},
  metadata: [:request_id, :correlation_id, :tenant_id]

# Section 24.1 bounds a status note at 1,000 Unicode code points, so lengths are
# counted in code points everywhere. Graphemes would leave `max_length`
# unbounded in bytes, since one grapheme can carry unlimited combining marks.
config :ash, default_string_length_count: :codepoints

config :phoenix, :json_library, Jason

# Section 21.3: one queue, FIFO by insertion. Section 27.6 forbids priority
# queues, so a single queue is the structural guarantee rather than a
# convention that a later job definition could quietly break.
config :dispatch, Oban,
  repo: Dispatch.Repo,
  queues: [operations: 20],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]

import_config "#{config_env()}.exs"
