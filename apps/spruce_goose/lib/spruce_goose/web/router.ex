defmodule SpruceGoose.Web.Router do
  @moduledoc """
  Routes for the OAuth 2.1 authorization server, the Ash AI MCP server, and
  the common ledger's change feed.

  Every route is rate-limited per client (`RateLimit`), in one of three
  buckets: `:sign_in` for sign-in and the OAuth protocol, `:capability` for
  what anyone holding a code or grant ID may ask without a session, and
  `:api` for the rest.

  The MCP surface is protected by `BearerPlug`, which validates an
  `Authorization: Bearer *** header against `SpruceGoose.Oauth2Server`, and by
  `RequireScopePlug`, which enforces the exact `mcp` delegated scope. Missing,
  invalid, or insufficient tokens fail closed before actor resolution.
  """
  use Phoenix.Router
  use AshAuthentication.Phoenix.Oauth2Server.Router

  pipeline :sign_in_limit do
    plug(SpruceGoose.Web.RateLimit, :sign_in)
  end

  pipeline :capability_limit do
    plug(SpruceGoose.Web.RateLimit, :capability)
  end

  pipeline :api_limit do
    plug(SpruceGoose.Web.RateLimit, :api)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :mcp_protected do
    plug(SpruceGoose.Web.RateLimit, :api)
    plug(:accepts, ["json"])

    plug(AshAuthentication.Phoenix.Oauth2Server.BearerPlug,
      oauth2_server: SpruceGoose.Oauth2Server,
      required?: true,
      scope: "mcp"
    )

    plug(AshAuthentication.Phoenix.Oauth2Server.RequireScopePlug,
      oauth2_server: SpruceGoose.Oauth2Server,
      scope: "mcp"
    )

    # Resolve only the verified token claim client_id through the governed
    # immutable client-ID -> actor-ID map. OAuth user `sub` and registration
    # metadata are not actor authority inputs.
    plug(SpruceGoose.Web.ActorPlug)
  end

  scope "/" do
    pipe_through([:sign_in_limit, :browser])
    oauth2_server_consent_routes(oauth2_server: SpruceGoose.Oauth2Server)
  end

  scope "/" do
    pipe_through([:sign_in_limit, :api])
    oauth2_server_protocol_routes(oauth2_server: SpruceGoose.Oauth2Server)
  end

  # Human sign-in through BizKit.Identity's configured providers.
  scope "/auth", SpruceGoose.Web do
    pipe_through(:sign_in_limit)
    get("/:provider/login", AuthController, :login)
    get("/:provider/callback", AuthController, :callback)
    post("/logout", AuthController, :logout)
    get("/me", AuthController, :me)
  end

  # The minimal web view and the commands it signs.
  scope "/", SpruceGoose.Web do
    pipe_through(:api_limit)
    get("/app", AppController, :index)
    get("/app/:file", AppController, :file)
    post("/api/v1/commands/:id", CommandController, :submit)
    post("/api/v1/devices/challenges/:id", DeviceController, :prove)
  end

  # Asked without a session: a code or grant ID is the capability, and a
  # governance signature the authority.
  scope "/", SpruceGoose.Web do
    pipe_through(:capability_limit)
    get("/api/v1/enrolments/:code", EnrolmentController, :show)
    post("/api/v1/enrolments/:code/approval", EnrolmentController, :prepare)
    post("/api/v1/enrolments/:code/approval/:id", EnrolmentController, :approve)
    get("/api/v1/grants/:id", GrantController, :show)
    post("/api/v1/grants/:id/revocation", GrantController, :prepare)
    post("/api/v1/grants/:id/revocation/:held_id", GrantController, :revoke)
  end

  # The common ledger's change feed. Authenticated by CoopSubstrate's own
  # grants (FeedController), not the OAuth pipeline above.
  scope "/api/v1/chapters/:chapter_id/tenants/:tenant_id/projects/:project_id",
        SpruceGoose.Web do
    pipe_through(:api_limit)
    get("/feed", FeedController, :stream)
    post("/commands", CommandController, :prepare)
    get("/devices", DeviceController, :index)
    post("/devices", DeviceController, :request)
    post("/devices/:grant_id/revocation", DeviceController, :revoke)
    get("/devices/:key_id", DeviceController, :status)
  end

  scope "/mcp" do
    pipe_through(:mcp_protected)

    forward("/", AshAi.Mcp.Router,
      tools: [
        :list_tasks,
        :list_projects,
        :list_roadmaps,
        :list_workflows,
        :list_todos
      ],
      protocol_version_statement: "2024-11-05",
      otp_app: :spruce_goose
    )
  end
end
