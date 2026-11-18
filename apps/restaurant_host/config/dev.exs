import Config

ip = {127, 0, 0, 1}
host = ip |> :inet.ntoa() |> to_string()
port = 4070

config :restaurant_host, RestaurantHost.Web.Endpoint,
  http: [ip: ip, port: port],
  url: [scheme: "http", host: host, port: port],
  check_origin: ["http://#{host}:#{port}"],
  secret_key_base: String.duplicate("dev-only-restaurant-host-secret", 3),
  server: true
