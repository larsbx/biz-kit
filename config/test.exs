import Config

config :dispatch, Dispatch.Repo,
  url:
    System.get_env("DATABASE_URL", "ecto://dispatch:dispatch@localhost:5432/dispatch_test")
    |> then(&(&1 <> System.get_env("MIX_TEST_PARTITION", ""))),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :dispatch, DispatchWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: String.duplicate("test-only-secret-key-base", 3),
  server: false

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
  # Test-only, compiled from test/support. Section 22.2 lets profiles other than
  # DRIVER declare a different assignment cardinality; without a second profile
  # that branch cannot be exercised at all.
  Dispatch.Support.Roles.Courier,
  Dispatch.Access.Roles.Driver,
  Dispatch.Access.Roles.Admin,
  Dispatch.Access.Roles.Dispatcher,
  Dispatch.Access.Roles.Shipper,
  Dispatch.Access.Roles.Receiver,
  Dispatch.Access.Roles.Broker
]

config :dispatch, :diagnostics_token, String.duplicate("test-diagnostics-token", 2)

config :dispatch, Oban, testing: :manual

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
