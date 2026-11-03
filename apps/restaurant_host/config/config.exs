import Config

# The rebuilt eatsbot's host. Each restaurant device signs with its own key;
# seeds and board pairing secrets come from the environment at runtime
# (config/runtime.exs), never from source.
config :restaurant_host, RestaurantHost.Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: RestaurantHost.Web.ErrorHTML], layout: false],
  pubsub_server: RestaurantHost.PubSub,
  live_view: [signing_salt: "restaurant-host-lv"]

import_config "#{config_env()}.exs"
