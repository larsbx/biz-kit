# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ex_cldr, default_backend: Eatsbot.Cldr
# Internal decimal strings use a dot; presentation passes the Gettext locale.
config :localize,
  default_locale: :en,
  supported_locales: [:en, :es],
  otp_app: :eatsbot,
  allow_runtime_locale_download: false

config :ex_money, auto_start_exchange_rate_service: false

# Shared with the umbrella's other apps, so only settings they agree with live
# here. eatsbot's own read behaviour is set by Eatsbot.Application at startup.
config :ash,
  default_string_length_count: :codepoints,
  # Read at compile time, as a name lookup only. `known_types`, which Ash loads at
  # runtime, is registered by Eatsbot.Application: the other apps lack ash_money.
  custom_types: [money: AshMoney.Types.Money]

# custom_types: [ticket_status: Eatsbot.Support.Ticket.Types.Status]

config :opentelemetry_ash,
  trace_types: [:custom, :action, :flow]

config :eatsbot,
  ecto_repos: [Eatsbot.Repo],
  generators: [timestamp_type: :utc_datetime],
  extensions: [
    Eatsbot.Extensions.TelegramBot,
    Eatsbot.Extensions.Prometheus
  ],
  pubsub: Eatsbot.PubSub,
  geocoding_endpoint: "https://nominatim.openstreetmap.org/search",
  # set to 0 to disable stale cleaner
  days_for_stale: 2,
  min_done_distance_meters: 50,
  ash_domains: [
    EatsbotCore.Deliveries,
    EatsbotCore.Products,
    EatsbotCore.Carts,
    EatsbotCore.Orders,
    EatsbotCore.Brands,
    EatsbotCore.Marketing,
    Eatsbot.Accounts,
    Eatsbot.Extensions.TelegramBot.Ash.Users
  ],
  from_email: {"noreply", "noreply@example.com"},
  magic_link_subject: "Your login link"

# Configures the endpoint
config :eatsbot, EatsbotWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EatsbotWeb.ErrorHTML, json: EatsbotWeb.ErrorJSON],
    root_layout: {EatsbotWeb.Layouts, "root.html"},
    # Error assigns do not carry the browser layout's required flash state.
    layout: false
  ],
  pubsub_server: Eatsbot.PubSub,
  live_view: [signing_salt: "x8OTxxKq"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :eatsbot, Eatsbot.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  eatsbot: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    # The umbrella keeps every dependency in its root deps/.
    env: %{"NODE_PATH" => Path.expand("../../../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  eatsbot: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Import Telegram Bot Extension
# Uncomment if needed

import_config Path.expand(
                "../../eatsbot_extension_telegram_bot/config/#{config_env()}.exs",
                __DIR__
              )
