# Runtime configuration for the whole release. Mix and releases read exactly one
# runtime.exs and it may not import other files, so each app's former
# apps/<app>/config/runtime.exs lives here as its own section, unchanged except
# for paths, which are now relative to this directory.
import Config

# ── dispatch (from d-patch/central) ─────────────────────────────────────────
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

# ── spruce_goose (from sprucegoose) ─────────────────────────────────────────
if config_env() == :test do
  if marker = System.get_env("SPRUCE_GOOSE_TEST_AUTHORITY_MARKER") do
    config :spruce_goose, :authority_host_marker, marker
  end

  if System.get_env("SPRUCE_GOOSE_TEST_DOGFOOD") == "true" do
    config :spruce_goose, SpruceGoose.Repo, pool: DBConnection.ConnectionPool
  end
end

config :spruce_goose,
       :systemwide_sop_path,
       System.get_env(
         "SYSTEMWIDE_SOP_PATH",
         if(config_env() == :test,
           do: Path.expand("../apps/spruce_goose/test/fixtures/systemwide-sop.md", __DIR__),
           else: "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md"
         )
       )

outbox_flag = System.get_env("OUTBOX_DISPATCHER_ENABLED", "false")
outbox_enabled? = outbox_flag == "1" or outbox_flag == "true"
oban_enabled? = System.get_env("SPRUCE_GOOSE_OBAN_ENABLED", "true") in ["1", "true"]

if outbox_enabled? and not oban_enabled? do
  raise "OUTBOX_DISPATCHER_ENABLED requires SPRUCE_GOOSE_OBAN_ENABLED"
end

outbox_handler =
  case System.get_env("OUTBOX_HANDLER") do
    nil ->
      nil

    name ->
      name
      |> String.trim_leading("Elixir.")
      |> String.split(".")
      |> Module.concat()
  end

if outbox_enabled? and is_nil(outbox_handler),
  do: raise("OUTBOX_HANDLER is required when OUTBOX_DISPATCHER_ENABLED is true")

if outbox_enabled? do
  case SpruceGoose.Outbox.Dispatcher.validate_handler(outbox_handler) do
    :ok -> :ok
    {:error, message} -> raise message
  end
end

config :spruce_goose,
  start_outbox_dispatcher: outbox_enabled?,
  outbox_handler: outbox_handler,
  derivation_executor_actor:
    (case System.get_env("SPRUCE_GOOSE_DERIVATION_EXECUTOR_ACTOR") do
       value when is_binary(value) and value != "" -> value
       _ -> nil
     end),
  deployment_executor_actor:
    (case System.get_env("SPRUCE_GOOSE_DEPLOYMENT_EXECUTOR_ACTOR") do
       value when is_binary(value) and value != "" -> value
       _ -> nil
     end)

if not oban_enabled? do
  config :spruce_goose, Oban, queues: false, plugins: false
end

config :spruce_goose,
  ledger_import_root: System.get_env("LEDGER_IMPORT_ROOT"),
  ledger_max_bytes: String.to_integer(System.get_env("LEDGER_MAX_BYTES", "1048576")),
  ledger_max_lines: String.to_integer(System.get_env("LEDGER_MAX_LINES", "10000")),
  ledger_open_timeout_ms: String.to_integer(System.get_env("LEDGER_OPEN_TIMEOUT_MS", "1000")),
  ledger_recovery_mode: System.get_env("LEDGER_RECOVERY_MODE", "false") in ["1", "true"],
  ledger_recovery_database: System.get_env("LEDGER_RECOVERY_DATABASE")

config :spruce_goose,
  forgejo_read_token_file:
    System.get_env(
      "SPRUCE_GOOSE_FORGEJO_READ_TOKEN_FILE",
      Application.get_env(
        :spruce_goose,
        :forgejo_read_token_file,
        "/home/admin-papa/.config/sprucegoose/forgejo-read-token"
      )
    ),
  forgejo_api_url:
    System.get_env(
      "SPRUCE_GOOSE_FORGEJO_API_URL",
      Application.get_env(
        :spruce_goose,
        :forgejo_api_url,
        "https://ubuntu-8gb-hil-1.tail2188e6.ts.net:8448/api/v1"
      )
    ),
  blueprint_max_bytes:
    String.to_integer(System.get_env("SPRUCE_GOOSE_BLUEPRINT_MAX_BYTES", "1048576"))

config :spruce_goose,
  artifact_store_root:
    System.get_env(
      "ARTIFACT_STORE_ROOT",
      if(config_env() == :prod,
        do: "/var/lib/sprucegoose/artifacts",
        else: Path.join(System.tmp_dir!(), "sprucegoose-artifacts")
      )
    ),
  artifact_max_bytes: String.to_integer(System.get_env("ARTIFACT_MAX_BYTES", "67108864"))

if outbox_enabled? do
  config :spruce_goose, Oban,
    plugins: [
      {Oban.Plugins.Cron, crontab: SpruceGoose.Outbox.Dispatcher.cron_config()}
    ]
end

cli_service_enabled? =
  System.get_env("SPRUCE_GOOSE_CLI_SERVICE_ENABLED", "false") in ["1", "true"]

# `UID` is a bash shell variable, not an exported environment variable, so the
# old fallback resolved to "/run/user/" and the socket landed at
# /run/user/sprucegoose/cli.sock — outside the per-user runtime directory whose
# 0700 mode is the entire authentication boundary. Refuse instead of guessing.
cli_socket_path =
  case {System.get_env("SPRUCE_GOOSE_CLI_SOCKET"), System.get_env("XDG_RUNTIME_DIR")} do
    {path, _} when is_binary(path) and path != "" ->
      path

    {_, runtime_dir} when is_binary(runtime_dir) and runtime_dir != "" ->
      Path.join(runtime_dir, "sprucegoose/cli.sock")

    _ ->
      if cli_service_enabled? do
        raise "XDG_RUNTIME_DIR is unset; set it or name the socket explicitly with " <>
                "SPRUCE_GOOSE_CLI_SOCKET. The socket directory's mode is the only " <>
                "authentication boundary on the CLI service"
      end
  end

config :spruce_goose,
  start_cli_service: cli_service_enabled?,
  cli_socket_path: cli_socket_path,
  cli_request_timeout:
    String.to_integer(System.get_env("SPRUCE_GOOSE_CLI_REQUEST_TIMEOUT_MS", "30000"))

# MCP/OAuth endpoint. Opt-in and loopback-only.
#
# SpruceGoose is CLI-first; nothing binds a port unless this is switched on.
# The bind address is deliberately not configurable from the environment:
# exposing the MCP tool surface beyond loopback is a separate, governed
# security decision, not an ops toggle.
mcp_enabled? = System.get_env("SPRUCE_GOOSE_MCP_ENABLED", "false") in ["1", "true"]

config :spruce_goose, :start_web_endpoint, mcp_enabled?

if mcp_enabled? do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is required when SPRUCE_GOOSE_MCP_ENABLED is true"

  if byte_size(secret_key_base) < 64 do
    raise "SECRET_KEY_BASE must be at least 64 bytes; generate one with `mix phx.gen.secret`"
  end

  for {var, setting} <- [
        {"TOKEN_SIGNING_SECRET", :token_signing_secret},
        {"OAUTH2_SIGNING_SECRET", :oauth2_signing_secret}
      ] do
    case System.get_env(var) do
      nil ->
        if config_env() == :prod,
          do: raise("#{var} is required when SPRUCE_GOOSE_MCP_ENABLED is true")

      value ->
        config :spruce_goose, [{setting, value}]
    end
  end

  oauth_actor_bindings =
    case System.get_env("SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS") do
      value when is_binary(value) and value != "" ->
        uuid = ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

        value
        |> String.split(",", trim: true)
        |> Enum.reduce(%{}, fn entry, bindings ->
          case String.split(entry, "=", parts: 2) do
            [client_id, actor_id] ->
              if not Regex.match?(uuid, client_id) or not Regex.match?(uuid, actor_id) do
                raise "SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS entries must be canonical lowercase UUID=UUID pairs"
              end

              if Map.has_key?(bindings, client_id) do
                raise "SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS contains duplicate OAuth client ID #{client_id}"
              end

              Map.put(bindings, client_id, actor_id)

            _ ->
              raise "SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS entries must be canonical lowercase UUID=UUID pairs"
          end
        end)

      _ ->
        raise "SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS is required when MCP is enabled"
    end

  config :spruce_goose, :oauth_client_actor_bindings, oauth_actor_bindings

  config :spruce_goose, SpruceGoose.Web.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("MCP_PORT", "4000"))],
    secret_key_base: secret_key_base,
    server: true
end

if config_env() == :prod do
  expected_genesis_actor =
    case System.get_env("SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR") do
      value when is_binary(value) and value != "" -> value
      _ -> raise "SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR is required in production"
    end

  config :spruce_goose, :expected_genesis_actor, expected_genesis_actor

  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is required in production"

  ssl_flag = System.get_env("DATABASE_SSL", "true")
  ssl = ssl_flag != "false" and ssl_flag != "0"

  # `ssl: true` alone leaves peer verification to library and OTP defaults, so
  # whether the connection was actually verified depended on nothing stated
  # here. For a system whose entire authority lives in this database, that is
  # pinned explicitly. DATABASE_CA_CERT_FILE names a bundle; otherwise the
  # system store is used, which OTP exposes as :public_key.cacerts_get/0.
  ssl_opts =
    if ssl do
      cacert =
        case System.get_env("DATABASE_CA_CERT_FILE") do
          value when is_binary(value) and value != "" -> [cacertfile: value]
          _ -> [cacerts: :public_key.cacerts_get()]
        end

      [
        verify: :verify_peer,
        depth: 3,
        server_name_indication: String.to_charlist(URI.parse(database_url).host || ""),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ] ++ cacert
    end

  config :spruce_goose, SpruceGoose.Repo,
    url: database_url,
    ssl: if(ssl, do: ssl_opts, else: false),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  config :spruce_goose,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")
end
