defmodule DispatchWeb.OperationsControllerTest do
  @moduledoc "`/v1/operations`: the carrier's dispatch board over HTTP."

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Dispatch.Support.Fixtures
  alias Dispatch.Support.Tokens.StaticVerifier

  @moduletag :integration

  @opts DispatchWeb.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    org = Fixtures.carrier()
    tenant = org.id
    %{user: desk, participant: dispatcher} = Fixtures.person(tenant, org)
    Fixtures.assignment(tenant, org, dispatcher, "DISPATCHER")
    %{user: field, participant: driver} = Fixtures.person(tenant, org, display_name: "Dana")
    Fixtures.assignment(tenant, org, driver, "DRIVER")

    %{
      driver: driver,
      token: StaticVerifier.token_for(desk.oidc_subject),
      driver_token: StaticVerifier.token_for(field.oidc_subject)
    }
  end

  defp call(method, path, token, body \\ nil, headers \\ []) do
    method
    # A map becomes `body_params`, as Plug.Parsers would leave it.
    |> conn(path, body || %{})
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> then(&Enum.reduce(headers, &1, fn {k, v}, c -> put_req_header(c, k, v) end))
    |> DispatchWeb.Router.call(@opts)
  end

  defp decoded(conn), do: Jason.decode!(conn.resp_body)

  test "a dispatcher creates a load, adds a stop, plans and starts a trip", ctx do
    conn = call(:post, "/v1/operations/loads", ctx.token, %{"commodity_text" => "Pallets"})
    assert conn.status == 201
    %{"load_id" => id, "status" => "DRAFT", "stops" => [], "trips" => []} = decoded(conn)

    conn =
      call(:post, "/v1/operations/loads/#{id}/stops", ctx.token, %{
        "kind" => "PICKUP",
        "address_text" => "1 Dock Rd"
      })

    assert %{"stops" => [%{"sequence" => 1, "kind" => "PICKUP"}]} = decoded(conn)

    conn =
      call(:post, "/v1/operations/loads/#{id}/trips", ctx.token, %{
        "operator_participant_id" => ctx.driver.id
      })

    assert %{"trips" => [%{"assignment_id" => trip, "status" => "PLANNED", "version" => v}]} =
             decoded(conn)

    conn =
      call(:post, "/v1/operations/trips/#{trip}/transitions", ctx.token, %{
        "action" => "activate",
        "expected_version" => v
      })

    assert conn.status == 200
    assert %{"trips" => [%{"status" => "ACTIVE"}]} = decoded(conn)

    assert %{"loads" => [%{"load_id" => ^id}]} =
             decoded(call(:get, "/v1/operations/loads", ctx.token))

    assert %{"drivers" => [%{"public_name" => "Dana"}]} =
             decoded(call(:get, "/v1/operations/fleet", ctx.token))
  end

  test "a retried create under one Idempotency-Key makes one load", ctx do
    key = [{"idempotency-key", "load-1"}]
    first = call(:post, "/v1/operations/loads", ctx.token, %{"commodity_text" => "A"}, key)
    again = call(:post, "/v1/operations/loads", ctx.token, %{"commodity_text" => "A"}, key)

    assert decoded(first)["load_id"] == decoded(again)["load_id"]
    assert [_one] = decoded(call(:get, "/v1/operations/loads", ctx.token))["loads"]
  end

  test "a stale transition is a 409 and a driver gets a 403", ctx do
    %{"load_id" => id} = decoded(call(:post, "/v1/operations/loads", ctx.token, %{}))

    %{"trips" => [%{"assignment_id" => trip, "version" => v}]} =
      decoded(
        call(:post, "/v1/operations/loads/#{id}/trips", ctx.token, %{
          "operator_participant_id" => ctx.driver.id
        })
      )

    conn =
      call(:post, "/v1/operations/trips/#{trip}/transitions", ctx.token, %{
        "action" => "cancel",
        "expected_version" => v + 1
      })

    assert {conn.status, decoded(conn)["code"]} == {409, "STALE_VERSION"}

    conn = call(:get, "/v1/operations/loads", ctx.driver_token)
    assert {conn.status, decoded(conn)["code"]} == {403, "FORBIDDEN"}
  end
end
