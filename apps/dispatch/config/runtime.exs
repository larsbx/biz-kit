import Config

# Section 31: secrets are loaded at runtime, never committed or embedded in
# images, and startup fails closed when a selected adapter's required
# production secret is absent.

require_env = fn name ->
  System.get_env(name) ||
    raise """
    Environment variable #{name} is required but not set.
    """
end

# What a compile-time file already selected. An unset environment variable must
# mean "leave this alone", not "reset it to the production default": this file
# runs in every environment, so a hardcoded default here silently replaces the
# selection `config/test.exs` and `config/dev.exs` made. That is how a test
# double gets swapped for the real adapter with nothing in the diff to show it.
configured = fn group, key, default ->
  :dispatch |> Application.get_env(group, []) |> Keyword.get(key, default)
end

# Section 28.5's map port holds a descriptor name rather than a module, so it is
# downcased to an atom instead of resolved to a module.
name_env = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value -> value |> String.downcase() |> String.to_atom()
  end
end

module_env = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value -> Module.concat([value])
  end
end

integer_env = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value -> String.to_integer(value)
  end
end

boolean_env = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value -> String.downcase(value) in ~w(1 true yes)
  end
end

# Adapter selection applies in every environment so a developer can exercise a
# real provider locally without editing compiled configuration.
config :dispatch, :comms,
  messaging_adapter:
    module_env.(
      "COMMS_MESSAGING_ADAPTER",
      configured.(:comms, :messaging_adapter, Dispatch.Integrations.Comms.Unconfigured.Messaging)
    ),
  voice_adapter:
    module_env.(
      "COMMS_VOICE_ADAPTER",
      configured.(:comms, :voice_adapter, Dispatch.Integrations.Comms.Unconfigured.Voice)
    ),
  voice_media_adapter:
    module_env.(
      "COMMS_VOICE_MEDIA_ADAPTER",
      configured.(
        :comms,
        :voice_media_adapter,
        Dispatch.Integrations.Comms.Unconfigured.VoiceMedia
      )
    )

config :dispatch, :geo,
  geocoder:
    module_env.(
      "GEO_GEOCODER_ADAPTER",
      configured.(:geo, :geocoder, Dispatch.Integrations.Geo.Unconfigured.Geocoder)
    ),
  router:
    module_env.(
      "GEO_ROUTER_ADAPTER",
      configured.(:geo, :router, Dispatch.Integrations.Geo.Unconfigured.Router)
    ),
  map_presentation:
    name_env.("MAP_PRESENTATION_PROVIDER", configured.(:geo, :map_presentation, :google))

config :dispatch, :agent,
  runtime:
    module_env.(
      "AGENT_RUNTIME_ADAPTER",
      configured.(:agent, :runtime, Dispatch.Integrations.Agent.Fake.Runtime)
    ),
  streaming_runtime:
    module_env.(
      "AGENT_STREAMING_RUNTIME_ADAPTER",
      configured.(:agent, :streaming_runtime, Dispatch.Integrations.Agent.Fake.StreamingRuntime)
    )

config :dispatch, :identity,
  face_verifier:
    module_env.(
      "FACE_VERIFIER_ADAPTER",
      configured.(:identity, :face_verifier, Dispatch.Identity.Face.DisabledVerifier)
    ),
  face_1_to_1_enabled:
    boolean_env.("FACE_1_TO_1_ENABLED", configured.(:identity, :face_1_to_1_enabled, false)),
  face_challenge_ttl_seconds:
    integer_env.(
      "FACE_CHALLENGE_TTL_SECONDS",
      configured.(:identity, :face_challenge_ttl_seconds, 120)
    ),
  manifest_public_key: System.get_env("FACE_POLICY_MANIFEST_PUBLIC_KEY"),
  face_attestation_retention_days: System.get_env("FACE_ATTESTATION_RETENTION_DAYS"),
  consent_text_version: System.get_env("FACE_CONSENT_TEXT_VERSION"),
  jurisdiction_policy_version: System.get_env("FACE_JURISDICTION_POLICY_VERSION"),
  token_verifier:
    module_env.(
      "TOKEN_VERIFIER_ADAPTER",
      configured.(:identity, :token_verifier, Dispatch.Identity.Tokens.Oidc)
    )

config :dispatch, :breakglass,
  enabled: boolean_env.("BREAKGLASS_ENABLED", false),
  max_ttl_seconds:
    integer_env.(
      "BREAKGLASS_MAX_TTL_SECONDS",
      configured.(:breakglass, :max_ttl_seconds, 1_800)
    ),
  nonprod_single_user_mode:
    boolean_env.(
      "BREAKGLASS_NONPROD_SINGLE_USER_MODE",
      configured.(:breakglass, :nonprod_single_user_mode, false)
    ),
  runbook_allowlist:
    System.get_env("BREAKGLASS_RUNBOOK_ALLOWLIST", "") |> String.split(",", trim: true)

# Section 23.2: only modules compiled into the release and listed here may be
# referenced by role_definitions.profile_module.
#
# Set only when the variable is present. An unset variable must not overwrite
# the compile-time list: doing so narrowed the development allowlist to nothing
# and made every role definition fail validation, which reads as a seed bug
# rather than a configuration one.
if allowlist = System.get_env("ROLE_PROFILE_MODULE_ALLOWLIST") do
  modules =
    allowlist
    |> String.split(",", trim: true)
    |> Enum.map(&Module.concat([String.trim(&1)]))

  if modules != [] do
    config :dispatch, :role_profile_module_allowlist, modules
  end
end

if config_env() == :prod do
  config :dispatch, Dispatch.Repo,
    url: require_env.("DATABASE_URL"),
    pool_size: integer_env.("POOL_SIZE", 10),
    ssl: true

  %URI{host: host, scheme: scheme, port: port} = URI.parse(require_env.("PUBLIC_BASE_URL"))

  config :dispatch, DispatchWeb.Endpoint,
    url: [host: host, scheme: scheme, port: port || 443],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: integer_env.("PORT", 4000)],
    secret_key_base: require_env.("SECRET_KEY_BASE"),
    server: true

  config :dispatch,
    oidc_issuer: require_env.("OIDC_ISSUER"),
    oidc_client_id_api: require_env.("OIDC_CLIENT_ID_API"),
    oidc_audience: require_env.("OIDC_AUDIENCE"),
    application_encryption_key_id: require_env.("APPLICATION_ENCRYPTION_KEY_ID"),
    diagnostics_token: require_env.("DIAGNOSTICS_TOKEN")
else
  config :dispatch,
    oidc_issuer: System.get_env("OIDC_ISSUER", "http://localhost:5556/dex"),
    oidc_client_id_api: System.get_env("OIDC_CLIENT_ID_API", "dispatch-api"),
    oidc_audience: System.get_env("OIDC_AUDIENCE", "dispatch-api")

  if url = System.get_env("DATABASE_URL") do
    config :dispatch, Dispatch.Repo, url: url
  end
end

# The Section 31 fail-closed check runs in `Dispatch.Application.start/2`, not
# here: `Application.get_env/2` cannot observe values this file is still
# building, so validating at boot is the only point where the whole selection is
# readable. A violation there aborts the supervision tree, so the release exits
# without binding a port.
