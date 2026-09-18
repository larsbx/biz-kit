import Config

config :dispatch, Dispatch.Repo,
  url: System.get_env("DATABASE_URL", "ecto://dispatch:dispatch@localhost:5432/dispatch_dev"),
  pool_size: 10,
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :dispatch, DispatchWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: String.duplicate("dev-only-secret-key-base", 3),
  watchers: []

# Development starts with no telecom, geospatial, or agent credential. Every
# port selects its deterministic unconfigured adapter; `Dispatch.Config` rejects
# these in production.
config :dispatch, :comms,
  messaging_adapter: Dispatch.Integrations.Comms.Unconfigured.Messaging,
  voice_adapter: Dispatch.Integrations.Comms.Unconfigured.Voice,
  voice_media_adapter: Dispatch.Integrations.Comms.Unconfigured.VoiceMedia

config :dispatch, :geo,
  geocoder: Dispatch.Integrations.Geo.Unconfigured.Geocoder,
  router: Dispatch.Integrations.Geo.Unconfigured.Router,
  map_presentation: :google

config :dispatch, :agent,
  runtime: Dispatch.Integrations.Agent.Fake.Runtime,
  streaming_runtime: Dispatch.Integrations.Agent.Fake.StreamingRuntime

config :dispatch, :identity,
  face_verifier: Dispatch.Identity.Face.DisabledVerifier,
  face_1_to_1_enabled: false,
  face_challenge_ttl_seconds: 120

config :dispatch, :breakglass,
  max_ttl_seconds: 1_800,
  nonprod_single_user_mode: true

# Section 23.2: only these compiled modules may be named by a role definition.
config :dispatch, :role_profile_module_allowlist, [
  Dispatch.Access.Roles.Driver,
  Dispatch.Access.Roles.Admin,
  Dispatch.Access.Roles.Dispatcher,
  Dispatch.Access.Roles.Shipper,
  Dispatch.Access.Roles.Receiver,
  Dispatch.Access.Roles.Broker
]

config :dispatch, :diagnostics_token, String.duplicate("dev-diagnostics-token", 2)

config :logger, level: :debug
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
