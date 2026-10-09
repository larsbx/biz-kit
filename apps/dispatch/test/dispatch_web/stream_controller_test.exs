defmodule DispatchWeb.StreamControllerTest do
  @moduledoc """
  The SSE endpoint's transport contract (Sections 24.5, 33.2).

  The stream's authorization over time is covered by
  `DispatchWeb.Streams.ParticipantTest`, which drives it a tick at a time. What
  is left for this level is what only a real connection shows: the headers, the
  refusal, and that an unauthorized request carries no fragment.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Dispatch.Support.Fixtures
  alias DispatchWeb.Plugs.PortalSession

  @moduletag :integration

  @opts DispatchWeb.Router.init([])

  @session Plug.Session.init(
             store: :cookie,
             key: "_dispatch_session",
             signing_salt: "5xJq0pQe",
             encryption_salt: "Nn4vT2kA"
           )

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Dispatch.Repo)

    carrier = Fixtures.carrier()
    tenant = carrier.id

    %{participant: driver} = Fixtures.person(tenant, carrier)
    %{user: dispatcher_user, participant: dispatcher} = Fixtures.person(tenant, carrier)
    assignment = Fixtures.assignment(tenant, carrier, dispatcher, "DISPATCHER")

    %{
      tenant: tenant,
      carrier: carrier,
      driver: driver,
      dispatcher_user: dispatcher_user,
      assignment: assignment
    }
  end

  defp with_secret(conn) do
    put_in(
      conn.secret_key_base,
      Application.get_env(:dispatch, DispatchWeb.Endpoint)[:secret_key_base]
    )
  end

  defp get(path, session_entries) do
    :get
    |> conn(path)
    |> with_secret()
    |> Plug.Session.call(@session)
    |> fetch_session()
    |> then(fn conn ->
      Enum.reduce(session_entries, conn, fn {k, v}, acc -> put_session(acc, k, v) end)
    end)
    |> DispatchWeb.Router.call(@opts)
  end

  defp signed_in(ctx) do
    [
      {PortalSession.subject_key(), ctx.dispatcher_user.oidc_subject},
      {PortalSession.assignment_key(), ctx.assignment.id}
    ]
  end

  describe "an unauthorized stream" do
    test "returns no fragment and no protected content", ctx do
      elsewhere = Fixtures.carrier()
      %{participant: stranger} = Fixtures.person(elsewhere.id, elsewhere)

      conn = get("/ui/participants/#{stranger.id}/stream", signed_in(ctx))

      # Section 33.2: "An unauthorized stream and map-data request returns no
      # protected fragment or coordinates."
      assert conn.status == 404
      assert conn.resp_body == ""
      refute conn.resp_body =~ "datastar-patch-elements"
    end

    test "an unauthenticated request never reaches the stream at all", ctx do
      conn = get("/ui/participants/#{ctx.driver.id}/stream", [])

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/login"]
      refute conn.resp_body =~ "participant-status-card"
    end

    test "a revoked assignment cannot open one", ctx do
      Fixtures.revoke(ctx.tenant, ctx.assignment)

      conn = get("/ui/participants/#{ctx.driver.id}/stream", signed_in(ctx))

      # Section 33.2 names SSE reconnects specifically: a client reconnecting
      # after revocation must not get back in.
      assert conn.status in [302, 404]
      refute conn.resp_body =~ "participant-status-card"
    end
  end
end
