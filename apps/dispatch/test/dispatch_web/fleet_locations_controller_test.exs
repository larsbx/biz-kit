defmodule DispatchWeb.FleetLocationsControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Dispatch.Operations.{LocationDemand, Locations}
  alias Dispatch.Support.{Fixtures, PortalIdentity}
  alias DispatchWeb.Plugs.PortalSession

  @moduletag :integration
  @session Plug.Session.init(
             store: :cookie,
             key: "_dispatch_session",
             signing_salt: "5xJq0pQe",
             encryption_salt: "Nn4vT2kA"
           )

  defmodule LogoutAfterSnapshot do
    defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn

    def chunk(%{after_snapshot: after_snapshot} = state, data) do
      if state[:snapshot_written],
        do: ExUnit.Assertions.flunk("location frame emitted after source logout")

      {:ok, body, state} = Plug.Adapters.Test.Conn.chunk(state, data)
      after_snapshot.()
      send(self(), {:outbox, :test_refresh})
      {:ok, body, Map.put(state, :snapshot_written, true)}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    :ok = PortalIdentity.setup()
    carrier = Fixtures.carrier()
    %{user: user, participant: desk} = Fixtures.person(carrier.id, carrier)
    tracker = Fixtures.tracker(carrier.id, carrier, desk)
    %{participant: driver} = Fixtures.person(carrier.id, carrier)
    driver_actor = Fixtures.actor(carrier.id, carrier, driver, "DRIVER")
    trip = Fixtures.assignment_record(carrier.id, carrier, driver)
    {device, seed} = Fixtures.keyed_device(carrier.id, driver)
    {:ok, grant} = Locations.begin_consent(driver_actor, trip.id)
    sample = Fixtures.location_sample(%{trip: trip, device: device, seed: seed}, grant)
    {:ok, [%{result: "ACCEPTED"}]} = Locations.ingest(driver_actor, [sample])

    %{
      carrier: carrier,
      user: user,
      desk: desk,
      tracker: tracker,
      driver: driver,
      token: PortalIdentity.token_for(user.oidc_subject)
    }
  end

  defp request(ctx, path, role \\ nil) do
    role = role || ctx.tracker.role_assignment

    :get
    |> conn(path)
    |> put_req_header("accept", "application/json")
    |> put_in(
      [Access.key(:secret_key_base)],
      Application.get_env(:dispatch, DispatchWeb.Endpoint)[:secret_key_base]
    )
    |> Plug.Session.call(@session)
    |> fetch_session()
    |> put_session(PortalSession.subject_key(), ctx.user.oidc_subject)
    |> put_session(PortalSession.assignment_key(), role.id)
    |> put_session(PortalSession.reference_key(), BizKit.Identity.Sessions.reference(ctx.token))
    |> DispatchWeb.Router.call(DispatchWeb.Router.init([]))
  end

  test "the same-origin JSON route uses the selected session and forbids caching", ctx do
    response = request(ctx, "/ui/operations/locations")
    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
    decoded = Jason.decode!(response.resp_body)
    assert decoded["status"] == "ok"
    driver = Enum.find(decoded["participants"], &(&1["participant_id"] == ctx.driver.id))
    assert driver["position"]["lat"] == 51.5074
    refute LocationDemand.watched?(ctx.driver.id)
  end

  test "ordinary dispatch authority opens neither protected JSON nor stream", ctx do
    role = Fixtures.assignment(ctx.carrier.id, ctx.carrier, ctx.desk, "DISPATCHER")

    for path <- ["/ui/operations/locations", "/ui/operations/locations/stream"] do
      response = request(ctx, path, role)
      assert response.status == 404
      assert Jason.decode!(response.resp_body) == %{"error" => "not_found"}
      refute response.resp_body =~ "51.5074"
    end
  end

  test "the real stream loop ends at source logout and releases demand", ctx do
    page = request(ctx, "/ui/operations/locations")
    assert page.status == 200

    stream =
      conn(:get, "/ui/operations/locations/stream")
      |> init_test_session(get_session(page))
      |> assign(:actor, page.assigns.actor)

    {Plug.Adapters.Test.Conn, state} = stream.adapter
    state = Map.put(state, :after_snapshot, fn -> BizKit.Identity.logout(ctx.token) end)
    stream = %{stream | adapter: {LogoutAfterSnapshot, state}}
    finished = DispatchWeb.FleetLocationsController.stream(stream, %{})

    assert finished.state == :chunked
    assert finished.resp_body =~ "event: dispatch-locations"
    assert get_resp_header(finished, "cache-control") == ["no-store"]
    assert get_resp_header(finished, "x-accel-buffering") == ["no"]
    refute LocationDemand.watched?(ctx.driver.id)
    assert request(ctx, "/ui/operations/locations/stream").status == 302
  end
end
