defmodule EatsbotWeb.Router do
  use EatsbotWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAdmin.Router
  import Plug.BasicAuth

  pipeline :graphql do
    plug :load_from_bearer
    plug :set_actor, :user
    plug EatsbotWeb.Deliveries.DeliveryAuthPlug
    plug AshGraphql.Plug
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EatsbotWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug EatsbotWeb.Deliveries.DeliveryAuthPlug
    plug :load_from_bearer
    plug :set_actor, :user
  end

  pipeline :admin do
    plug :admin_basic_auth
  end

  defp admin_basic_auth(conn, _opts) do
    case System.get_env("ADMIN_API_KEY") do
      password when is_binary(password) and password != "" ->
        basic_auth(conn, username: "admin", password: password)

      _ ->
        conn |> request_basic_auth() |> Plug.Conn.halt()
    end
  end

  scope "/", EatsbotWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes do
      # in each liveview, add one of the following at the top of the module:
      #
      # If an authenticated user must be present:
      # on_mount {EatsbotWeb.LiveUserAuth, :live_user_required}
      #
      # If an authenticated user *may* be present:
      # on_mount {EatsbotWeb.LiveUserAuth, :live_user_optional}
      #
      # If an authenticated user must *not* be present:
      # on_mount {EatsbotWeb.LiveUserAuth, :live_no_user}
    end
  end

  scope "/gql" do
    pipe_through [:graphql]

    forward "/playground",
            Absinthe.Plug.GraphiQL,
            schema: Module.concat(["EatsbotWeb.GraphqlSchema"]),
            analyze_complexity: true,
            max_complexity: 1_000,
            interface: :playground

    forward "/",
            Absinthe.Plug,
            schema: Module.concat(["EatsbotWeb.GraphqlSchema"]),
            analyze_complexity: true,
            max_complexity: 1_000
  end

  scope "/", EatsbotWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/map", MapLive

    magic_sign_in_route(Eatsbot.Accounts.User, :magic_link,
      auth_routes_prefix: "/auth",
      path: "/auth/user/magic_link",
      token_as_route_param?: false,
      overrides: [AshAuthentication.Phoenix.Overrides.Default]
    )

    auth_routes AuthController, Eatsbot.Accounts.User, path: "/auth"
    sign_out_route AuthController

    sign_in_route reset_path: "/reset",
                  auth_routes_prefix: "/auth",
                  on_mount: [{EatsbotWeb.LiveUserAuth, :live_no_user}],
                  overrides: [AshAuthentication.Phoenix.Overrides.Default]

    ash_authentication_live_session :authentication_required,
      on_mount: {EatsbotWeb.LiveUserAuth, :live_user_admin_required} do
      live "/deliveries", DeliveryLive.Index, :index
      live "/deliveries/new", DeliveryLive.Index, :new
      live "/deliveries/:id/edit", DeliveryLive.Index, :edit

      live "/deliveries/:id", DeliveryLive.Show, :show
      live "/deliveries/:id/show/edit", DeliveryLive.Show, :edit
    end
  end

  scope "/" do
    pipe_through :browser
    pipe_through :admin

    ash_admin("/admin")
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:eatsbot, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: EatsbotWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
