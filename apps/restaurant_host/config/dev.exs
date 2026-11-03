import Config

config :restaurant_host, RestaurantHost.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4070],
  secret_key_base: String.duplicate("dev-only-restaurant-host-secret", 3),
  server: true
