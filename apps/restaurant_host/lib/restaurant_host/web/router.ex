defmodule RestaurantHost.Web.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RestaurantHost.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"cache-control" => "no-store"}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # `mix restaurant.grant`: only a governance signature on the held grant is
  # ever admitted, so these routes need no session.
  scope "/api", RestaurantHost.Web do
    pipe_through :api

    get "/restaurant-menu", DeviceGrantController, :menu
    post "/restaurant-management/:operation", DeviceGrantController, :prepare_management
    post "/restaurant-management/:operation/:id", DeviceGrantController, :submit_management

    get "/device-grants/:device", DeviceGrantController, :show
    post "/device-grants/:device", DeviceGrantController, :prepare
    post "/device-grants/:device/:id", DeviceGrantController, :submit
  end

  scope "/", RestaurantHost.Web do
    pipe_through :browser

    get "/auth/login", AuthController, :login
    get "/auth/callback", AuthController, :callback
    post "/auth/logout", AuthController, :logout
    live "/", StorefrontLive
    live "/account/orders", AccountLive
    get "/board/pair/:board/:secret", PairController, :pair
    live "/board", BoardLive
  end
end
