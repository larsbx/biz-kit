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

# Read once: the identity section below selects it, and the production block
# requires the OIDC issuer's settings only when it is the OIDC verifier.
dispatch_token_verifier =
  module_env.(
    "TOKEN_VERIFIER_ADAPTER",
    configured.(:identity, :token_verifier, Dispatch.Identity.Tokens.Oidc)
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
  token_verifier: dispatch_token_verifier

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

# The capability document's Ed25519 seed (base64url, 32 bytes). Unset leaves the
# compiled development seed outside production and nothing in it, which
# `Dispatch.Config` then refuses.
if seed = System.get_env("DISPATCH_CAPABILITY_SIGNING_SEED") do
  config :dispatch, :capability_signing_seed, seed
end

# Which apps this boot carries. A release runs this whole file, so each app's
# production section is gated on the release that ships it (mix.exs); an unset
# RELEASE_NAME (a Mix run) carries every app. The `orchestration` release has no
# dispatch, and the `eatsbot` release has only eatsbot.
release_name = System.get_env("RELEASE_NAME")
dispatch_released? = release_name not in ["orchestration", "eatsbot"]
spruce_goose_released? = release_name != "eatsbot"
eatsbot_released? = release_name in [nil, "eatsbot"]

if config_env() == :prod and dispatch_released? do
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
    application_encryption_key_id: require_env.("APPLICATION_ENCRYPTION_KEY_ID"),
    diagnostics_token: require_env.("DIAGNOSTICS_TOKEN")

  # Only the OIDC token verifier reads its issuer settings. A deployment that
  # selects biz-kit sessions instead (Dispatch.Identity.Tokens.BizKitSession,
  # docs/architecture/2026-10-21-native-sign-in.md) needs none of them.
  if dispatch_token_verifier == Dispatch.Identity.Tokens.Oidc do
    config :dispatch,
      oidc_issuer: require_env.("OIDC_ISSUER"),
      oidc_client_id_api: require_env.("OIDC_CLIENT_ID_API"),
      oidc_audience: require_env.("OIDC_AUDIENCE")
  end
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
  outbox_handler: outbox_handler

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

# The boot-time Systemwide SOP adoption check guards the legacy SpruceGoose
# writer, whose CLI service gates work on that file. The ledger names each
# task's SOP by digest in its readiness definition instead, so a node serving
# only the ledger and the web view needs no SOP file (docs/deploy.md).
if config_env() == :prod and spruce_goose_released? and not cli_service_enabled? do
  config :spruce_goose, :verify_sop_adoption, false
end

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

if config_env() == :prod and spruce_goose_released? do
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

# ── coop_substrate ──────────────────────────────────────────────────────────
# The common ledger's event store. SpruceGoose's release starts the ledger to
# serve its change feed. apps/coop_substrate/config/config.exs reads these at
# build time, which would bake the build host's credentials into a release, so
# production reads them at boot.
# Operational records share its database, in their own schema.
if config_env() == :prod do
  for store <- [CoopSubstrate.EventStore, CoopSubstrate.Records] do
    config :coop_substrate, store,
      database: System.get_env("EVENTSTORE_DATABASE", "coop_substrate_eventstore"),
      username: System.get_env("EVENTSTORE_USERNAME", "postgres"),
      password: System.get_env("EVENTSTORE_PASSWORD"),
      hostname: System.get_env("EVENTSTORE_HOST", "localhost"),
      port: String.to_integer(System.get_env("EVENTSTORE_PORT", "5432"))
  end
end

# ── biz_kit_identity ────────────────────────────────────────────────────────
# Native apps' sessions last until the person signs out, kept by hash in
# SpruceGoose's Postgres so a restart does not end them
# (docs/architecture/2026-10-21-native-sign-in.md). Both releases carry
# SpruceGoose; tests of the apps that do not configure their own.
if config_env() in [:dev, :prod] do
  config :biz_kit_identity, :session_store, SpruceGoose.Web.NativeSessionStore
end

# Human sign-in. WorkOS is the first provider; any BizKit.Identity.Provider can
# take its place. Bindings map a verified {issuer, subject} to a biz-kit
# principal, and are administrator-controlled: JSON
# [{"issuer": …, "subject": …, "principal": "prn_…"}]. Malformed bindings
# refuse boot (BizKit.Identity.Application).
if config_env() == :prod do
  if client_id = System.get_env("WORKOS_CLIENT_ID") do
    config :biz_kit_identity, :providers, %{
      "workos" =>
        {BizKit.Identity.Providers.WorkOS,
         client_id: client_id,
         api_key:
           System.get_env("WORKOS_API_KEY") ||
             raise("WORKOS_API_KEY is required when WORKOS_CLIENT_ID is set")}
    }
  end
end

# Development sign-in, for local runs and the end-to-end stack: each
# "name=subject" in BIZKIT_DEVELOPMENT_SIGN_IN becomes a provider that signs in
# as that subject with no real provider (BizKit.Identity.Providers.Development).
# It works only where :allow_development_provider is set, which is here alone.
if config_env() == :dev do
  config :biz_kit_identity, :allow_development_provider, true

  # scripts/e2e-stack.sh signs a whole cast in, from one address, within a
  # minute. It is not the limiter's test, so it raises that bucket alone.
  if limit = System.get_env("SPRUCE_GOOSE_SIGN_IN_LIMIT") do
    config :spruce_goose, SpruceGoose.Web.RateLimit,
      overrides: %{sign_in: {String.to_integer(limit), 60_000}}
  end

  # Development serves /auth over plain HTTP; a secure cookie would never come
  # back, and sign-in could not complete. Every other environment keeps it.
  config :spruce_goose, :secure_cookies, false

  if people = System.get_env("BIZKIT_DEVELOPMENT_SIGN_IN") do
    config :biz_kit_identity,
           :providers,
           for(
             entry <- String.split(people, ",", trim: true),
             [name, subject] = entry |> String.trim() |> String.split("=", parts: 2),
             into: %{},
             do: {name, {BizKit.Identity.Providers.Development, subject: subject}}
           )
  end
end

if config_env() in [:dev, :prod] do
  if bindings = System.get_env("BIZKIT_IDENTITY_BINDINGS") do
    config :biz_kit_identity,
           :bindings,
           for(
             b <- :json.decode(bindings),
             do: %{issuer: b["issuer"], subject: b["subject"], principal: b["principal"]}
           )
  end

  # Native apps' redirect URIs, comma-separated and matched exactly
  # (docs/architecture/2026-10-21-native-sign-in.md), e.g. the field app's
  # "com.dispatch.driver:/oauth2redirect". Unset, no native app can sign in.
  if uris = System.get_env("BIZKIT_NATIVE_REDIRECT_URIS") do
    config :biz_kit_identity,
           :native_redirect_uris,
           uris |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  if public_url = System.get_env("SPRUCE_GOOSE_PUBLIC_URL") do
    config :spruce_goose, :public_url, public_url
  end
end

if config_env() == :prod do
  # The other nodes of this service's cluster, e.g.
  # "biz_kit@10.0.0.11,biz_kit@10.0.0.12" (docs/architecture/2026-10-19-cluster.md).
  # Each node also needs RELEASE_DISTRIBUTION=name, its own RELEASE_NODE and
  # the cluster's shared RELEASE_COOKIE.
  if nodes = System.get_env("BIZKIT_CLUSTER_NODES") do
    config :biz_kit_cluster,
           :nodes,
           nodes |> String.split(",", trim: true) |> Enum.map(&String.to_atom(String.trim(&1)))
  end

  # Reverse proxies whose x-forwarded-for is believed, e.g. "10.0.0.0/8,::1".
  if proxies = System.get_env("SPRUCE_GOOSE_TRUSTED_PROXIES") do
    config :spruce_goose,
           SpruceGoose.Web.RateLimit,
           trusted_proxies: proxies |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end
end

# Separate proof-reference encryption key; no production default. A deployment
# without one can read other partner data but reference additions fail closed.
if config_env() == :prod do
  case System.get_env("DOCUMENT_REFERENCE_KEY") do
    nil ->
      :ok

    encoded ->
      case Base.decode64(encoded) do
        {:ok, key} when byte_size(key) == 32 -> config :dispatch, :document_reference_key, key
        _ -> raise "DOCUMENT_REFERENCE_KEY must be base64 for 32 bytes"
      end
  end
end

# ── eatsbot (from larsbx/eatsbot) ───────────────────────────────────────────
# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/eatsbot start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :eatsbot, EatsbotWeb.Endpoint, server: true
end

# Marketing agent: public base URL encoded on counter NFC/QR stickers and the
# bot they deep-link into (see EatsbotCore.Marketing for all options).
config :eatsbot,
       EatsbotCore.Marketing,
       Enum.reject(
         [
           public_url: System.get_env("PUBLIC_URL"),
           telegram_bot_username: System.get_env("TELEGRAM_BOT_USERNAME")
         ],
         &is_nil(elem(&1, 1))
       )

# Telegram bot: read at boot, so one built release serves any bot. The webhook
# rejects updates without the secret it registers with Telegram, so a webhook
# without one could never take an update.
if eatsbot_released? do
  telegram_webhook = System.get_env("TELEGRAM_WEBHOOK")
  telegram_webhook_secret = System.get_env("TELEGRAM_WEBHOOK_SECRET")

  if (telegram_webhook != nil or telegram_webhook_secret != nil) and
       not (is_binary(telegram_webhook_secret) and
              Regex.match?(~r/\A[A-Za-z0-9_-]{1,256}\z/, telegram_webhook_secret)) do
    raise """
    environment variable TELEGRAM_WEBHOOK_SECRET is missing or invalid.
    TELEGRAM_WEBHOOK is set, and the webhook accepts only updates carrying the
    secret: 1-256 characters from A-Z, a-z, 0-9, _ and -.
    """
  end

  if token = System.get_env("TELEGRAM_BOT_TOKEN"), do: config(:telegex, token: token)

  config :eatsbot,
         Eatsbot.Extensions.TelegramBot.Handler,
         Enum.reject(
           [webhook_url: telegram_webhook, webhook_secret: telegram_webhook_secret],
           &is_nil(elem(&1, 1))
         )
end

if config_env() == :prod and eatsbot_released? do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # config :opentelemetry_exporter,
  #   otlp_protocol: :http_protobuf,
  #   otlp_endpoint: System.fetch_env!("OTLP_ENDPOINT")

  config :eatsbot, Eatsbot.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :eatsbot, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :eatsbot, EatsbotWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  config :eatsbot,
    geocoding_token: System.fetch_env!("GEOCODING_TOKEN"),
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!"),
    req_impl: Req

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :eatsbot, EatsbotWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :eatsbot, EatsbotWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :eatsbot, Eatsbot.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
