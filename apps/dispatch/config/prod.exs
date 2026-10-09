import Config

# Section 22: production MUST NOT auto-migrate on boot.
config :dispatch, Dispatch.Repo, migration_source: "schema_migrations"

config :dispatch, DispatchWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]]

config :logger, level: :info
