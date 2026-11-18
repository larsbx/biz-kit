defmodule DispatchWeb.PartnerApiControllerTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  import Plug.Test
  import Plug.Conn
  alias Dispatch.Support.{Fixtures, Tokens.StaticVerifier}
  alias Dispatch.Operations.StopReadinessEvent
  require Ash.Query
  @opts DispatchWeb.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    carrier = Fixtures.carrier()
    t = carrier.id
    org = Fixtures.organization(t, :SHIPPER)
    %{user: user, participant: participant} = Fixtures.person(t, org)
    load = Fixtures.load(t, carrier, agreed_rate_minor: 917_500, currency: "USD")
    stop = Fixtures.stop(t, load, :PICKUP, sequence: 1)
    other = Fixtures.stop(t, load, :DELIVERY, sequence: 2)
    Fixtures.stop_party(t, stop, org, :SHIPPER)
    actor = Fixtures.actor(t, org, participant, "SHIPPER", scope_id: stop.id)
    %{tenant: t, org: org, stop: stop, other: other, user: user, actor: actor}
  end

  defp request(c, method, path, body \\ %{}, key \\ "partner-test-key") do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> StaticVerifier.token_for(c.user.oidc_subject))
    |> put_req_header("x-role-assignment-id", c.actor.role_assignment.id)
    |> then(fn conn -> if key, do: put_req_header(conn, "idempotency-key", key), else: conn end)
    |> Plug.RequestId.call(Plug.RequestId.init(assign_as: :correlation_id))
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> DispatchWeb.Router.call(@opts)
  end

  test "the machine action and retry return one attributed readiness report", c do
    path = "/v1/stops/#{c.stop.id}/readiness-events"
    params = %{state: "READY", expected_version: 0}
    first = request(c, :post, path, params)
    assert first.status == 201
    assert Jason.decode!(first.resp_body)["source"] == "PARTICIPANT"
    replay = request(c, :post, path, params)
    assert replay.status == 201
    assert replay.resp_body == first.resp_body
    assert length(Ash.read!(StopReadinessEvent, tenant: c.tenant, authorize?: false)) == 1
    assert request(c, :post, path, %{state: "BLOCKED", expected_version: 0}).status == 409
    assert get_resp_header(first, "cache-control") == ["no-store"]
  end

  test "unrelated, foreign and missing subjects have identical API 404s", c do
    denied = request(c, :get, "/v1/stops/#{c.other.id}")
    absent = request(c, :get, "/v1/stops/#{Ash.UUID.generate()}")
    assert denied.status == 404
    assert denied.resp_body == absent.resp_body

    for id <- [c.other.id, Ash.UUID.generate()] do
      conn =
        request(c, :post, "/v1/stops/#{id}/readiness-events", %{
          state: "READY",
          expected_version: 0
        })

      assert conn.status == 404
      refute conn.resp_body =~ id
    end
  end

  test "an old idempotency response cannot bypass ended access", c do
    path = "/v1/stops/#{c.stop.id}/readiness-events"
    params = %{state: "READY", expected_version: 0}
    assert request(c, :post, path, params).status == 201
    Fixtures.end_stop_party(c.tenant, c.stop, c.org)
    assert request(c, :post, path, params).status == 404
  end

  test "a missing key, missing version or forged approval is refused without a write", c do
    path = "/v1/stops/#{c.stop.id}/readiness-events"
    assert request(c, :post, path, %{state: "READY", expected_version: 0}, nil).status == 400
    assert request(c, :post, path, %{state: "READY"}).status == 422

    assert request(c, :post, "/v1/actions/proposals", %{
             stop_id: c.stop.id,
             kind: "INSTRUCTION",
             instructions: "Change",
             expected_version: 0,
             expires_at: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600)),
             state: "APPROVED"
           }).status == 422

    assert [] == Ash.read!(StopReadinessEvent, tenant: c.tenant, authorize?: false)
  end
end
