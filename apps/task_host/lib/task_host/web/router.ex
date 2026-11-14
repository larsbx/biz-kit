defmodule TaskHost.Web.Router do
  @moduledoc """
  Routes of the task host: human and native sign-in (`/auth`), the minimal web
  view and the commands it signs, and the common ledger's change feed.

  Moved from SpruceGoose (docs/architecture/2026-11-09-task-host.md). Its
  OAuth 2.1 issuer and the Ash AI `/mcp` surface were not moved: they served
  SpruceGoose's own Ash resources, which retire with it.
  """
  use Phoenix.Router

  # Human sign-in through BizKit.Identity's configured providers.
  scope "/auth", TaskHost.Web do
    get("/:provider/login", AuthController, :login)
    get("/:provider/native/login", AuthController, :native_login)
    get("/:provider/callback", AuthController, :callback)
    post("/token", AuthController, :token)
    post("/logout", AuthController, :logout)
    get("/me", AuthController, :me)
  end

  # The minimal web view and the commands it signs.
  scope "/", TaskHost.Web do
    get("/app", AppController, :index)
    get("/app/:file", AppController, :file)
    get("/operations", AppController, :operations)
    get("/operations/knowledge", AppController, :knowledge)

    get(
      "/operations/workspaces/:workspace_id/infrastructure-review",
      InfrastructureReviewController,
      :show
    )

    get("/api/v1/operations", OperationsController, :index)
    get("/api/v1/operations/knowledge", KnowledgeController, :index)
    get("/api/v1/operations/knowledge/workflows/:id", KnowledgeController, :workflow)
    get("/api/v1/operations/knowledge/workflows/:id/manifest", KnowledgeController, :manifest)
    get("/api/v1/operations/knowledge/workflows/:id/sop", KnowledgeController, :sop)

    get(
      "/api/v1/operations/knowledge/documents/:id",
      KnowledgeController,
      :show
    )

    post("/api/v1/commands/:id", CommandController, :submit)
    post("/api/v1/devices/challenges/:id", DeviceController, :prove)
    get("/api/v1/enrolments/:code", EnrolmentController, :show)
    post("/api/v1/enrolments/:code/approval", EnrolmentController, :prepare)
    post("/api/v1/enrolments/:code/approval/:id", EnrolmentController, :approve)
    get("/api/v1/grants/:id", GrantController, :show)
    post("/api/v1/grants/:id/revocation", GrantController, :prepare)
    post("/api/v1/grants/:id/revocation/:held_id", GrantController, :revoke)
    get("/api/v1/principals/:id", PrincipalController, :show)
    post("/api/v1/principals/:id/offboarding", PrincipalController, :prepare)
    post("/api/v1/principals/:id/offboarding/:held_id", PrincipalController, :offboard)
    post("/api/v1/principals/:id/chapter_offboarding", PrincipalController, :prepare_chapter)

    post(
      "/api/v1/principals/:id/chapter_offboarding/:held_id",
      PrincipalController,
      :offboard_chapter
    )

    get("/api/v1/chapters/:chapter_id/administrators", AdministratorController, :index)
    get("/api/v1/chapters/:chapter_id/projects", AdministratorController, :projects)

    get(
      "/api/v1/chapters/:chapter_id/ownerless_projects",
      ProjectOwnershipController,
      :index
    )

    post(
      "/api/v1/chapters/:chapter_id/tenants/:tenant_id/projects/:project_id/ownership/backfill/:principal_id",
      ProjectOwnershipController,
      :prepare
    )

    post(
      "/api/v1/chapters/:chapter_id/tenants/:tenant_id/projects/:project_id/ownership/backfill/:principal_id/:held_id",
      ProjectOwnershipController,
      :backfill
    )

    post(
      "/api/v1/chapters/:chapter_id/administrators/:key_id/revocation",
      AdministratorController,
      :prepare
    )

    post(
      "/api/v1/chapters/:chapter_id/administrators/:key_id/revocation/:held_id",
      AdministratorController,
      :revoke
    )
  end

  # The common ledger's change feed. Authenticated by CoopSubstrate's own
  # grants (FeedController), not the OAuth pipeline above: a project's, and a
  # chapter's for its administrators.
  scope "/api/v1/chapters/:chapter_id", TaskHost.Web do
    get("/feed", FeedController, :stream)
  end

  scope "/api/v1/chapters/:chapter_id/tenants/:tenant_id/projects/:project_id",
        TaskHost.Web do
    get("/feed", FeedController, :stream)
    post("/commands", CommandController, :prepare)
    get("/devices", DeviceController, :index)
    post("/devices", DeviceController, :request)
    post("/devices/:id/revocation", DeviceController, :revoke)
    post("/artifacts", ArtifactController, :create)
    get("/receipts/:receipt_id", ArtifactController, :show)
    get("/tasks/:task_id/evidence", ArtifactController, :evidence)
    get("/tasks/:task_id", TaskController, :show)
    post("/tasks/:task_id/cancellation", TaskController, :prepare)
    post("/tasks/:task_id/cancellation/:held_id", TaskController, :cancel)
    post("/blueprints", BlueprintController, :prepare)
    post("/blueprints/:held_id", BlueprintController, :apply)
    post("/runs/:run_event_id/readiness", RunReadinessController, :prepare)
    post("/runs/:run_event_id/readiness/:held_id", RunReadinessController, :define)
    get("/devices/:key_id", DeviceController, :status)
  end
end
