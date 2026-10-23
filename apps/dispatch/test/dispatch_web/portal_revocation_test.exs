defmodule DispatchWeb.PortalRevocationTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias BizKit.Identity
  alias BizKit.Identity.Sessions
  alias Dispatch.Support.{Fixtures, PortalIdentity}
  alias DispatchWeb.Plugs.PortalSession
  alias DispatchWeb.Streams.{Operations, Participant}
  alias DispatchWeb.StreamController

  @moduletag :integration
  @session Plug.Session.init(
             store: :cookie,
             key: "_dispatch_session",
             signing_salt: "5xJq0pQe",
             encryption_salt: "Nn4vT2kA"
           )

  # Uses the real controller receive loop. The first successful snapshot write
  # is the barrier: revoke, queue a refresh, and forbid any subsequent chunk.
  defmodule RevokeAfterSnapshot do
    defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn

    def chunk(%{after_snapshot: after_snapshot} = state, data) do
      if state[:snapshot_written],
        do: ExUnit.Assertions.flunk("frame emitted after source logout")

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
    %{user: user, participant: person} = Fixtures.person(carrier.id, carrier)
    assignment = Fixtures.assignment(carrier.id, carrier, person, "DISPATCHER")
    %{participant: driver} = Fixtures.person(carrier.id, carrier)
    token = PortalIdentity.token_for(user.oidc_subject)
    login = request(nil, :get, "/login")
    [_all, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, login.resp_body)
    browser = request(login, :post, "/session", %{"token" => token, "_csrf_token" => csrf})
    assert browser.status == 302
    %{browser: browser, token: token, user: user, assignment: assignment, driver: driver}
  end

  defp request(previous, method, path, params \\ %{}) do
    method
    |> conn(path, params)
    |> put_in(
      [Access.key(:secret_key_base)],
      Application.get_env(:dispatch, DispatchWeb.Endpoint)[:secret_key_base]
    )
    |> then(&if previous, do: recycle_cookies(&1, previous), else: &1)
    |> Plug.Session.call(@session)
    |> fetch_session()
    |> DispatchWeb.Router.call(DispatchWeb.Router.init([]))
  end

  defp expire(token) do
    :sys.replace_state(BizKit.Cluster.Singleton.name(Sessions), fn state ->
      true = :ets.update_element(Sessions, {false, :crypto.hash(:sha256, token)}, {4, 0})
      state
    end)
  end

  test "cookie contents contain a non-bearer reference; normal sessions keep working", ctx do
    reference = get_session(ctx.browser, PortalSession.reference_key())
    assert is_binary(reference)
    refute reference == ctx.token
    refute inspect(get_session(ctx.browser)) =~ ctx.token
    assert {:error, :invalid_token} = Dispatch.Identity.Tokens.BizKitSession.verify(reference)
    assert {:ok, _, _} = PortalSession.authenticate(ctx.browser)
    assert request(ctx.browser, :get, "/select-role").status == 200
    assert request(ctx.browser, :get, "/operations").status == 200
    assert request(ctx.browser, :get, "/operations").status == 200
  end

  for ending <- [:logout, :portal_logout, :principal, :unbind, :expiry, :remote_logout] do
    @ending ending
    test "#{ending} ends pages, role selection, both stream ticks and reconnects", ctx do
      page = request(ctx.browser, :get, "/operations")
      assert page.status == 200
      choice = request(ctx.browser, :get, "/select-role")
      [_all, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, choice.resp_body)
      actor = page.assigns.actor
      assert {:ok, operations, _} = Operations.open(actor)
      assert {:ok, participant, _} = Participant.open(actor, ctx.driver.id)

      assert {:emit, _, _} =
               StreamController.authorized_tick(
                 page,
                 fn -> Operations.tick(operations, :heartbeat) end
               )

      assert {:emit, _, _} =
               StreamController.authorized_tick(
                 page,
                 fn -> Participant.tick(participant, :heartbeat) end
               )

      case @ending do
        :logout ->
          Identity.logout(ctx.token)

        :portal_logout ->
          signed_out = request(choice, :delete, "/session", %{"_csrf_token" => csrf})
          assert signed_out.status == 302
          refute get_session(signed_out, PortalSession.reference_key())

        :principal ->
          Identity.revoke_principal(ctx.user.oidc_subject)

        :unbind ->
          Application.put_env(:biz_kit_identity, :bindings, [])

        :expiry ->
          expire(ctx.token)

        :remote_logout ->
          BizKit.Cluster.Peers.distribute!()
          {_, peer} = BizKit.Cluster.Peers.start!()
          :ok = BizKit.Cluster.Peers.mesh!([peer])

          :ok =
            :erpc.call(peer, Application, :put_env, [
              :biz_kit_identity,
              :bindings,
              Application.get_env(:biz_kit_identity, :bindings)
            ])

          assert {:ok, _, _} = :erpc.call(peer, PortalSession, :authenticate, [page])
          :ok = :erpc.call(peer, Identity, :logout, [ctx.token])
          assert {:error, _} = :erpc.call(peer, PortalSession, :authenticate, [page])
      end

      # The role is deliberately unchanged: source state alone must end access.
      assert {:ok, _} =
               Dispatch.Identity.PrincipalResolution.actor(
                 ctx.user.oidc_subject,
                 ctx.assignment.id
               )

      for path <- [
            "/operations",
            "/select-role",
            "/ui/operations/stream",
            "/ui/participants/#{ctx.driver.id}/stream"
          ] do
        refused = request(ctx.browser, :get, path)
        assert refused.status == 302
        assert get_resp_header(refused, "location") == ["/login"]
        refute get_session(refused, PortalSession.reference_key())
      end

      refused_choice =
        request(choice, :post, "/select-role", %{
          "role_assignment_id" => ctx.assignment.id,
          "_csrf_token" => csrf
        })

      assert refused_choice.status == 302
      assert get_resp_header(refused_choice, "location") == ["/login"]

      for reason <- [:heartbeat, :refresh] do
        assert {:close, :unauthorized} =
                 StreamController.authorized_tick(
                   page,
                   fn -> Operations.tick(operations, reason) end
                 )

        assert {:close, :unauthorized} =
                 StreamController.authorized_tick(
                   page,
                   fn -> Participant.tick(participant, reason) end
                 )
      end
    end
  end

  for kind <- [:operations, :participant] do
    @kind kind
    test "the actual #{@kind} controller loop stops after source logout", ctx do
      page = request(ctx.browser, :get, "/operations")
      assert page.status == 200

      stream =
        conn(:get, "/stream")
        |> init_test_session(get_session(page))
        |> assign(:actor, page.assigns.actor)

      {Plug.Adapters.Test.Conn, state} = stream.adapter
      state = Map.put(state, :after_snapshot, fn -> Identity.logout(ctx.token) end)
      stream = %{stream | adapter: {RevokeAfterSnapshot, state}}

      finished =
        case @kind do
          :operations ->
            StreamController.operations(stream, %{})

          :participant ->
            StreamController.participant(stream, %{"participant_id" => ctx.driver.id})
        end

      assert finished.state == :chunked
      assert finished.resp_body =~ "event: datastar-patch-elements"
      assert {:error, _} = PortalSession.authenticate(finished)
    end
  end

  test "logout clears the browser cookie even while Identity is unavailable", ctx do
    choice = request(ctx.browser, :get, "/select-role")
    [_all, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, choice.resp_body)
    :ok = Supervisor.terminate_child(BizKit.Identity.Supervisor, Sessions)

    try do
      signed_out = request(choice, :delete, "/session", %{"_csrf_token" => csrf})
      assert signed_out.status == 503
      refute get_session(signed_out, PortalSession.reference_key())
      refute get_session(signed_out, PortalSession.subject_key())
      refute get_session(signed_out, PortalSession.assignment_key())
      assert signed_out.resp_body =~ "Signed out of this browser."
      assert request(signed_out, :get, "/operations").status == 302
    after
      {:ok, _} = Supervisor.restart_child(BizKit.Identity.Supervisor, Sessions)
    end
  end

  test "a verified subject without a revocable source cannot open a portal", ctx do
    Application.put_env(
      :dispatch,
      :identity,
      Keyword.put(
        Application.get_env(:dispatch, :identity),
        :token_verifier,
        Dispatch.Support.Tokens.StaticVerifier
      )
    )

    login = request(nil, :get, "/login")
    [_all, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, login.resp_body)

    refused =
      request(login, :post, "/session", %{
        "token" => Dispatch.Support.Tokens.StaticVerifier.token_for(ctx.user.oidc_subject),
        "_csrf_token" => csrf
      })

    assert refused.status == 401
    refute get_session(refused, PortalSession.reference_key())
  end

  test "legacy, malformed and mismatched browser bindings fail closed", ctx do
    for entries <- [
          %{PortalSession.subject_key() => ctx.user.oidc_subject},
          %{
            PortalSession.subject_key() => ctx.user.oidc_subject,
            PortalSession.reference_key() => "bogus"
          },
          %{
            PortalSession.subject_key() => "another-principal",
            PortalSession.reference_key() =>
              get_session(ctx.browser, PortalSession.reference_key())
          }
        ] do
      conn = conn(:get, "/") |> init_test_session(entries)
      assert {:error, _} = PortalSession.authenticate(conn)
    end
  end
end
