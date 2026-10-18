defmodule SpruceGoose.Web.Router do
  @moduledoc """
  Routes for the OAuth 2.1 authorization server, the Ash AI MCP server, and
  the common ledger's change feed.

  The MCP surface is protected by `BearerPlug`, which validates an
  `Authorization: Bearer *** header against `SpruceGoose.Oauth2Server`, and by
  `RequireScopePlug`, which enforces the exact `mcp` delegated scope. Missing,
  invalid, or insufficient tokens fail closed before actor resolution.
  """
  use Phoenix.Router
  use AshAuthentication.Phoenix.Oauth2Server.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :mcp_protected do
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
    pipe_through(:browser)
    oauth2_server_consent_routes(oauth2_server: SpruceGoose.Oauth2Server)
  end

  scope "/" do
    pipe_through(:api)
    oauth2_server_protocol_routes(oauth2_server: SpruceGoose.Oauth2Server)
  end

  # Human sign-in through BizKit.Identity's configured providers.
  scope "/auth", SpruceGoose.Web do
    get("/:provider/login", AuthController, :login)
    get("/:provider/callback", AuthController, :callback)
    post("/logout", AuthController, :logout)
    get("/me", AuthController, :me)
  end

  # The minimal web view and the commands it signs.
  scope "/", SpruceGoose.Web do
    get("/app", AppController, :index)
    get("/app/:file", AppController, :file)
    post("/api/v1/commands/:id", CommandController, :submit)
  end

  # The common ledger's change feed. Authenticated by CoopSubstrate's own
  # grants (FeedController), not the OAuth pipeline above.
  scope "/api/v1/chapters/:chapter_id/tenants/:tenant_id/projects/:project_id",
        SpruceGoose.Web do
    get("/feed", FeedController, :stream)
    post("/commands", CommandController, :prepare)
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
