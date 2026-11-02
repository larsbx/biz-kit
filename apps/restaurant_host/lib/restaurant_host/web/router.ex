defmodule RestaurantHost.Web.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RestaurantHost.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # `mix restaurant.grant`: only a governance signature on the held grant is
  # ever admitted, so these routes need no session.
  scope "/api", RestaurantHost.Web do
    pipe_through :api

    get "/device-grants/:device", DeviceGrantController, :show
    post "/device-grants/:device", DeviceGrantController, :prepare
    post "/device-grants/:device/:id", DeviceGrantController, :submit
  end

  scope "/", RestaurantHost.Web do
    pipe_through :browser

    live "/", StorefrontLive
    get "/board/pair/:board/:secret", PairController, :pair
    live "/board", BoardLive
  end
end
