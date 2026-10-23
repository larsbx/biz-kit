defmodule DispatchWeb.AssignmentControllerTest do
  @moduledoc "`GET /v1/me/assignments` and its DRIVER projection: the field app's own trips."

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Dispatch.Operations.Locations
  alias Dispatch.Support.Fixtures
  alias Dispatch.Support.Tokens.StaticVerifier

  @moduletag :integration

  @opts DispatchWeb.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    org = Fixtures.carrier()
    tenant = org.id
    %{user: user, participant: driver} = Fixtures.person(tenant, org)
    role = Fixtures.assignment(tenant, org, driver, "DRIVER")
    {:ok, actor} = Dispatch.Access.Actor.from_assignment(role)

    %{
      tenant: tenant,
      org: org,
      driver: driver,
      actor: actor,
      trip: Fixtures.assignment_record(tenant, org, driver),
      token: StaticVerifier.token_for(user.oidc_subject)
    }
  end

  defp get(path, token) do
    :get
    |> conn(path)
    |> put_req_header("authorization", "Bearer " <> token)
    |> DispatchWeb.Router.call(@opts)
  end

  test "lists the caller's trips, each with the consent covering it", ctx do
    {:ok, grant} = Locations.begin_consent(ctx.actor, ctx.trip.id)

    conn = get("/v1/me/assignments", ctx.token)

    assert conn.status == 200
    assert %{"assignments" => [trip]} = Jason.decode!(conn.resp_body)
    assert trip["assignment_id"] == ctx.trip.id
    assert trip["load_id"] == ctx.trip.load_id
    assert trip["status"] == "PLANNED"
    assert trip["location_consent"]["consent_grant_id"] == grant.id
    assert trip["location_consent"]["revoked_at"] == nil
  end

  test "a trip without consent says so with null", ctx do
    assert %{"assignments" => [%{"location_consent" => nil}]} =
             Jason.decode!(get("/v1/me/assignments", ctx.token).resp_body)
  end

  test "the DRIVER projection answers the same", ctx do
    assert get("/v1/driver/assignments", ctx.token).resp_body ==
             get("/v1/me/assignments", ctx.token).resp_body
  end

  test "a role that cannot read its own trips is refused", ctx do
    %{user: user, participant: desk} = Fixtures.person(ctx.tenant, ctx.org)
    Fixtures.assignment(ctx.tenant, ctx.org, desk, "DISPATCHER")

    conn = get("/v1/me/assignments", StaticVerifier.token_for(user.oidc_subject))

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["code"] == "FORBIDDEN"
  end
end
