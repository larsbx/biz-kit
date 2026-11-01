defmodule DispatchWeb.RoleCapabilityControllerTest do
  @moduledoc """
  The reads the field application makes before showing any role surface
  (Sections 23.2, 24.6), end to end: bearer token, selection, signed document.

  The document is verified here exactly as the client verifies it — signature
  first, then claims — so a test asserting on its contents is asserting on
  something a client would actually accept.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Dispatch.Access.CapabilitySigner
  alias Dispatch.Accounts.RoleDefinition
  alias Dispatch.Operations.Status
  alias Dispatch.Support.Fixtures
  alias Dispatch.Support.Tokens.StaticVerifier

  @moduletag :integration

  @opts DispatchWeb.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    org = Fixtures.carrier()
    tenant = org.id
    %{user: user, participant: driver} = Fixtures.person(tenant, org)
    assignment = Fixtures.assignment(tenant, org, driver, "DRIVER")
    {:ok, key} = CapabilitySigner.key()

    %{
      org: org,
      tenant: tenant,
      user: user,
      driver: driver,
      assignment: assignment,
      public: key.public,
      token: StaticVerifier.token_for(user.oidc_subject)
    }
  end

  defp get(path, opts) do
    headers =
      Keyword.get(opts, :headers, []) ++
        case Keyword.get(opts, :token) do
          nil -> []
          token -> [{"authorization", "Bearer " <> token}]
        end

    :get
    |> conn(path)
    |> Plug.RequestId.call(Plug.RequestId.init(assign_as: :correlation_id))
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> DispatchWeb.Router.call(@opts)
  end

  defp document(conn, public) do
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["key_id"] == CapabilitySigner.key_id(public)
    {:ok, claims} = CapabilitySigner.verify(body, public)
    claims
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["code"]

  describe "GET /v1/me/role-assignments" do
    test "lists every held assignment, even when no single one could be resolved", ctx do
      # The case the endpoint exists for: a caller holding two assignments
      # cannot yet name one, so `ResolveActor` would refuse them.
      dispatcher = Fixtures.assignment(ctx.tenant, ctx.org, ctx.driver, "DISPATCHER")

      conn = get("/v1/me/role-assignments", token: ctx.token)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      listed = Jason.decode!(conn.resp_body)["role_assignments"]

      assert Enum.sort(Enum.map(listed, & &1["id"])) ==
               Enum.sort([ctx.assignment.id, dispatcher.id])

      # Identifiers and labels only: nothing about what each one permits.
      assert Enum.all?(listed, &(Map.keys(&1) |> Enum.sort() == ["id", "label"]))
    end

    test "labels cross-organization roles and refuses a suspended home's roles", ctx do
      other_org = Fixtures.carrier()
      %{participant: colleague} = Fixtures.person(other_org.id, other_org, user: ctx.user)
      elsewhere = Fixtures.assignment(other_org.id, other_org, colleague, "DRIVER")

      response = get("/v1/me/role-assignments", token: ctx.token)
      assert response.status == 200

      listed = Jason.decode!(response.resp_body)["role_assignments"]
      assert %{"id" => ctx.assignment.id, "label" => "#{ctx.org.name} — #{ctx.assignment.role_definition.label}"} in listed
      assert %{"id" => elsewhere.id, "label" => "#{other_org.name} — #{elsewhere.role_definition.label}"} in listed

      other_org
      |> Ash.Changeset.for_update(:set_status, %{status: :SUSPENDED})
      |> Ash.update!(authorize?: false)

      response = get("/v1/me/role-assignments", token: ctx.token)
      assert response.status == 200
      assert [%{"id" => id}] = Jason.decode!(response.resp_body)["role_assignments"]
      assert id == ctx.assignment.id
    end

    test "omits another principal's assignments and revoked ones", ctx do
      %{participant: stranger} = Fixtures.person(ctx.tenant, ctx.org)
      _theirs = Fixtures.assignment(ctx.tenant, ctx.org, stranger, "DRIVER")
      revoked = Fixtures.assignment(ctx.tenant, ctx.org, ctx.driver, "DISPATCHER")
      Fixtures.revoke(ctx.tenant, revoked)

      conn = get("/v1/me/role-assignments", token: ctx.token)

      assert [%{"id" => id}] = Jason.decode!(conn.resp_body)["role_assignments"]
      assert id == ctx.assignment.id
    end

    test "is refused without a valid bearer token" do
      conn = get("/v1/me/role-assignments", token: nil)

      assert conn.status == 401
      assert code(conn) == "UNAUTHENTICATED"
    end
  end

  describe "GET /v1/role-capabilities" do
    test "signs a document bound to the caller and the selected assignment", ctx do
      claims = ctx |> then(&get("/v1/role-capabilities", token: &1.token)) |> document(ctx.public)

      assert claims["schema"] == "DispatchCapabilityDocumentV1"
      assert claims["schema_version"] == 1
      assert claims["sub"] == ctx.user.oidc_subject
      assert claims["tenant_id"] == ctx.tenant
      assert claims["participant_id"] == ctx.driver.id
      assert claims["role_assignment_id"] == ctx.assignment.id
      assert claims["exp"] - claims["iat"] == 12 * 60 * 60
    end

    test "publishes the manifest's capabilities with their constraints", ctx do
      claims = ctx |> then(&get("/v1/role-capabilities", token: &1.token)) |> document(ctx.public)

      assert %{"key" => "status.declare.self", "constraints" => ["self_only"]} in claims[
               "capabilities"
             ]

      assert %{
               "key" => "proposal.decide.self",
               "constraints" => ["requires_biometric", "self_only"]
             } in claims["capabilities"]
    end

    test "offers the status feature with the server's vocabulary", ctx do
      claims = ctx |> then(&get("/v1/role-capabilities", token: &1.token)) |> document(ctx.public)

      assert "status" in claims["features"]
      assert Enum.map(claims["status_options"], & &1["value"]) == Enum.map(Status.all(), &"#{&1}")

      assert %{"value" => "DELAYED", "label" => "Delayed", "requires_note" => true} in claims[
               "status_options"
             ]

      assert %{"value" => "AT_PICKUP", "requires_note" => false} =
               Enum.find(claims["status_options"], &(&1["value"] == "AT_PICKUP"))
    end

    test "a role without status.declare.self is offered no status surface", ctx do
      %{user: user, participant: admin} = Fixtures.person(ctx.tenant, ctx.org)
      Fixtures.assignment(ctx.tenant, ctx.org, admin, "ADMIN")

      claims =
        "/v1/role-capabilities"
        |> get(token: StaticVerifier.token_for(user.oidc_subject))
        |> document(ctx.public)

      refute "status" in claims["features"]
      assert claims["status_options"] == []
      refute Enum.any?(claims["capabilities"], &(&1["key"] == "status.declare.self"))
    end

    test "a new field profile gets the status surface from data alone (Section 33.2)", ctx do
      # A profile that lists `inbox` without `communications.read.self` is
      # published without it: a profile module cannot grant (Section 23.2).
      courier =
        RoleDefinition
        |> Ash.Changeset.for_create(:seed, %{
          tenant_id: ctx.tenant,
          key: "COURIER",
          label: "Courier",
          capabilities_json: ["status.declare.self"],
          profile_module: inspect(Dispatch.Support.Roles.Courier)
        })
        |> Ash.create!(authorize?: false, tenant: ctx.tenant)

      %{user: user, participant: operator} = Fixtures.person(ctx.tenant, ctx.org)

      Fixtures.assignment(ctx.tenant, ctx.org, operator, "COURIER",
        definition: courier,
        scope_type: :SELF
      )

      claims =
        "/v1/role-capabilities"
        |> get(token: StaticVerifier.token_for(user.oidc_subject))
        |> document(ctx.public)

      assert claims["features"] == ["home", "status"]
      assert claims["role"] == %{"key" => "COURIER", "label" => "Courier", "version" => 0}
      assert length(claims["status_options"]) == length(Status.all())
    end

    test "the header selects which assignment the document describes", ctx do
      dispatcher = Fixtures.assignment(ctx.tenant, ctx.org, ctx.driver, "DISPATCHER")

      claims =
        "/v1/role-capabilities"
        |> get(token: ctx.token, headers: [{"x-role-assignment-id", dispatcher.id}])
        |> document(ctx.public)

      assert claims["role_assignment_id"] == dispatcher.id
      refute "status" in claims["features"]
    end

    test "several assignments and no header is refused, not unioned", ctx do
      Fixtures.assignment(ctx.tenant, ctx.org, ctx.driver, "DISPATCHER")

      conn = get("/v1/role-capabilities", token: ctx.token)

      assert conn.status == 403
      assert code(conn) == "ROLE_ASSIGNMENT_REQUIRED"
    end

    test "another principal's assignment cannot be selected", ctx do
      %{participant: stranger} = Fixtures.person(ctx.tenant, ctx.org)
      theirs = Fixtures.assignment(ctx.tenant, ctx.org, stranger, "DRIVER")

      conn =
        get("/v1/role-capabilities",
          token: ctx.token,
          headers: [{"x-role-assignment-id", theirs.id}]
        )

      assert conn.status == 403
      assert code(conn) == "ROLE_ASSIGNMENT_INVALID"
    end

    test "a revoked assignment yields no document", ctx do
      Fixtures.revoke(ctx.tenant, ctx.assignment)

      conn = get("/v1/role-capabilities", token: ctx.token)

      assert conn.status == 403
      assert code(conn) == "NO_ACTIVE_ROLE_ASSIGNMENT"
    end

    test "is refused without a valid bearer token" do
      conn = get("/v1/role-capabilities", token: nil)

      assert conn.status == 401
      assert code(conn) == "UNAUTHENTICATED"
    end

    test "an unusable signing key yields a problem, never an unsigned document", ctx do
      original = Application.get_env(:dispatch, :capability_signing_seed)
      Application.put_env(:dispatch, :capability_signing_seed, "not a key")
      on_exit(fn -> Application.put_env(:dispatch, :capability_signing_seed, original) end)

      conn = get("/v1/role-capabilities", token: ctx.token)

      assert conn.status == 503
      assert code(conn) == "CAPABILITY_SIGNING_UNAVAILABLE"
      refute conn.resp_body =~ "document\""
    end
  end
end
