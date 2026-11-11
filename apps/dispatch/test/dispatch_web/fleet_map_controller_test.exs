defmodule DispatchWeb.FleetMapControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Dispatch.Support.{Fixtures, PortalIdentity}
  alias DispatchWeb.{FleetMapController, Router}
  alias DispatchWeb.Plugs.PortalSession

  @moduletag :integration
  @router Router.init([])
  @session Plug.Session.init(
             store: :cookie,
             key: "_dispatch_session",
             signing_salt: "5xJq0pQe",
             encryption_salt: "Nn4vT2kA"
           )

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)
    :ok = PortalIdentity.setup()
    carrier = Fixtures.carrier()
    %{user: user, participant: participant} = Fixtures.person(carrier.id, carrier)
    tracker = Fixtures.tracker(carrier.id, carrier, participant)
    dispatcher = Fixtures.actor(carrier.id, carrier, participant, "DISPATCHER")
    %{user: user, tracker: tracker, dispatcher: dispatcher}
  end

  test "a precise reader gets a small same-origin shell, with no embedded locations", ctx do
    conn = page("/operations/map", ctx.user, ctx.tracker)
    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert get_resp_header(conn, "content-security-policy") == [
             FleetMapController.content_security_policy()
           ]

    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert conn.resp_body =~ "id=\"dispatch-map-globe\""
    assert conn.resp_body =~ "/static/js/maps/dispatch-map.js"
    assert conn.resp_body =~ "/static/vendor/cesium/Widgets/widgets.css"
    refute conn.resp_body =~ "datastar.js"
    refute conn.resp_body =~ "live_position"
    refute conn.resp_body =~ "https://"

    assert FleetMapController.content_security_policy() =~
             "script-src 'self' 'wasm-unsafe-eval';"

    refute FleetMapController.content_security_policy() =~ "'unsafe-eval'"
    refute FleetMapController.content_security_policy() =~ "script-src 'self' 'unsafe-inline'"
  end

  test "ordinary dispatch authority does not grant the map or its navigation link", ctx do
    refused = page("/operations/map", ctx.user, ctx.dispatcher)
    assert refused.status == 404
    assert refused.resp_body == ""
    overview = page("/operations", ctx.user, ctx.dispatcher)
    assert overview.status == 200
    refute overview.resp_body =~ "href=\"/operations/map\""
    refute hd(get_resp_header(overview, "content-security-policy")) =~ "style-src-attr"
    refute hd(get_resp_header(overview, "content-security-policy")) =~ "wasm-unsafe-eval"
  end

  test "authorized operations navigation exposes the new view", ctx do
    conn = page("/operations", ctx.user, ctx.tracker)
    assert conn.status == 200
    assert conn.resp_body =~ "href=\"/operations/map\""
  end

  test "anonymous navigation enters the existing sign-in flow" do
    conn = request("/operations/map") |> Router.call(@router)
    assert conn.status == 302
    assert get_resp_header(conn, "location") == ["/login"]
    refute conn.resp_body =~ "dispatch-map-globe"
  end

  defp page(path, user, actor) do
    entries =
      PortalIdentity.bind([
        {PortalSession.subject_key(), user.oidc_subject},
        {PortalSession.assignment_key(), actor.role_assignment.id}
      ])

    Enum.reduce(entries, request(path), fn {key, value}, conn -> put_session(conn, key, value) end)
    |> Router.call(@router)
  end

  defp request(path) do
    conn(:get, path)
    |> Map.put(
      :secret_key_base,
      Application.fetch_env!(:dispatch, DispatchWeb.Endpoint)[:secret_key_base]
    )
    |> Plug.RequestId.call(Plug.RequestId.init(assign_as: :correlation_id))
    |> Plug.Session.call(@session)
    |> fetch_session()
  end
end
