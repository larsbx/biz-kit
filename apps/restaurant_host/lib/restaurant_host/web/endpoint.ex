defmodule RestaurantHost.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :restaurant_host

  @session [
    store: :cookie,
    key: "_restaurant_host",
    signing_salt: "restaurant-host",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]

  # The LiveView client ships inside the Phoenix and LiveView packages; no
  # asset build step.
  plug Plug.Static, at: "/assets", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/assets",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  plug Plug.RequestId

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["text/html", "application/json"],
    json_decoder: Jason,
    length: 64_000

  plug Plug.Session, @session
  plug RestaurantHost.Web.Router
end
