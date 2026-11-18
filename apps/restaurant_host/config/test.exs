import Config

config :restaurant_host, RestaurantHost.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4072],
  secret_key_base: String.duplicate("test-only-restaurant-host-secret", 3),
  server: false
