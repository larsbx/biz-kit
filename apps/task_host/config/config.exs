import Config

# The task host (docs/architecture/2026-11-09-task-host.md): sign-in, the web
# view, its signed commands and the change feed, moved from SpruceGoose.
config :task_host, ecto_repos: [TaskHost.Repo]

# Loopback by default. Exposing the host off-host is a deployment decision
# made in config/runtime.exs (TASK_HOST_IP), behind a reverse proxy.
config :task_host, TaskHost.Web.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "127.0.0.1"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: false,
  render_errors: [formats: [json: TaskHost.Web.ErrorJSON], layout: false]

# Requests per client per window (TaskHost.Web.RateLimit). Behind a reverse
# proxy, list its addresses in `trusted_proxies` so clients are told apart.
config :task_host, TaskHost.Web.RateLimit,
  limits: %{sign_in: {30, 60_000}, capability: {60, 60_000}, api: {600, 60_000}},
  trusted_proxies: []

config :task_host, TaskHost.Repo,
  username: "postgres",
  hostname: "localhost",
  port: 5432,
  database: "task_host_dev",
  pool_size: 5

# Blueprint sources (mix coop.blueprint): the forge each one is read from.
# Configuration, not a source default. These were hardcoded fallbacks inside
# the Forgejo verifier (now TaskHost.Blueprints.ForgejoVerifier), which meant production ran against
# whatever was compiled in and no deployment could say otherwise without an
# override that did not exist. runtime.exs takes the environment.
config :task_host,
       :forgejo_api_url,
       "https://ubuntu-8gb-hil-1.tail2188e6.ts.net:8448/api/v1"

config :task_host,
       :forgejo_read_token_file,
       "/home/admin-papa/.config/sprucegoose/forgejo-read-token"

# A blueprint manifest is a small YAML file. The verifier refuses anything
# larger rather than buffering it.
config :task_host, :blueprint_max_bytes, 1_048_576

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
