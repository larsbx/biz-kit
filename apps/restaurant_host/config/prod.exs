import Config

# Port, secret_key_base, device seeds and pairing secrets come from
# config/runtime.exs at boot.
config :restaurant_host, RestaurantHost.Web.Endpoint, server: true

config :restaurant_host, :secure_cookies, true
