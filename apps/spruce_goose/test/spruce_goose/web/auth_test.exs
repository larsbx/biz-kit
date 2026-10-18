defmodule SpruceGoose.Web.AuthTest do
  @moduledoc """
  Human sign-in and reads (docs/architecture/2026-10-18-identity.md): a
  provider authenticates, `BizKit.Identity` names the principal, the ledger's
  grants decide. The last test is the architecture's acceptance test: the
  provider is replaced and the principal keeps its grants, signing device and
  history.
  """
  use ExUnit.Case, async: false

  import SpruceGoose.LedgerFixtures

  alias BizKit.Identity.Principal
  alias BizKit.Identity.Providers.WorkOS
  alias CoopSubstrate.Log

  @workos_iss "https://api.workos.com/user_management/client_test"

  defmodule SecondProvider do
    @moduledoc "Another identity provider: the code is the subject."
    @behaviour BizKit.Identity.Provider

    @impl true
    def authorize_url(config, state, _redirect_uri),
      do: "#{config[:url]}/authorize?state=#{state}"

    @impl true
    def authenticate(config, code, _redirect_uri),
      do: {:ok, %{issuer: config[:url], subject: code}}
  end

  setup do
    env = Application.get_all_env(:biz_kit_identity)
    on_exit(fn -> Application.put_all_env(biz_kit_identity: env) end)

    Application.put_env(:biz_kit_identity, :providers, %{
      "workos" =>
        {WorkOS,
         client_id: "client_test",
         api_key: "sk_test",
         req_options: [plug: {Req.Test, WorkOS}, retry: false]},
      "second" => {SecondProvider, url: "https://idp.test"}
    })

    w = world()
    person = Principal.new_id()
    device = member("operator")
    grant = grant!(w, "TaskOperatorGrantedV1", device, person, "project-1")
    bind([{@workos_iss, "user_A", person}])

    Map.merge(w, %{person: person, device: device, person_grant: grant})
  end

  defp bind(bindings) do
    Application.put_env(
      :biz_kit_identity,
      :bindings,
      for({iss, sub, p} <- bindings, do: %{issuer: iss, subject: sub, principal: p})
    )
  end

  defp workos_signs_in(user_id) do
    Req.Test.stub(WorkOS, fn conn ->
      Req.Test.json(conn, %{"user" => %{"id" => user_id}, "access_token" => "x"})
    end)
  end

  defp cookie(conn, name), do: conn.resp_cookies[name][:value]

  # The browser's round trip: login redirect, provider, callback. Returns the
  # callback response.
  defp sign_in(provider, code) do
    login = call(:get, "/auth/#{provider}/login", [])
    state = cookie(login, "bizkit_login_state")

    call(:get, "/auth/#{provider}/callback?code=#{code}&state=#{state}", [
      {"cookie", "bizkit_login_state=#{state}"}
    ])
  end

  defp session!(provider, code) do
    conn = sign_in(provider, code)
    assert conn.status == 302
    "bizkit_session=" <> cookie(conn, "bizkit_session")
  end

  describe "sign-in" do
    test "sends the browser to the provider, remembering the state" do
      conn = call(:get, "/auth/workos/login", [])
      [location] = Plug.Conn.get_resp_header(conn, "location")
      query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert conn.status == 302
      assert location =~ "https://api.workos.com/user_management/authorize?"
      assert query["state"] == cookie(conn, "bizkit_login_state")
      assert query["redirect_uri"] =~ "/auth/workos/callback"
      assert conn.resp_cookies["bizkit_login_state"][:http_only]
    end

    test "issues an HttpOnly session for a bound identity" do
      workos_signs_in("user_A")
      conn = sign_in("workos", "code")

      assert conn.status == 302
      assert Plug.Conn.get_resp_header(conn, "location") == ["/"]
      assert %{http_only: true, same_site: "Lax"} = conn.resp_cookies["bizkit_session"]
    end

    test "refuses a forged state, an unbound identity, an unknown provider" do
      workos_signs_in("user_A")

      forged =
        call(:get, "/auth/workos/callback?code=c&state=evil", [
          {"cookie", "bizkit_login_state=good"}
        ])

      assert forged.status == 401
      assert call(:get, "/auth/workos/callback?code=c&state=s", []).status == 401

      workos_signs_in("user_B")
      assert sign_in("workos", "code").status == 401

      assert call(:get, "/auth/nope/login", []).status == 404
    end
  end

  describe "reading the feed as a person" do
    setup do
      %{base: serve!()}
    end

    test "needs the principal's own grant on the project", w do
      workos_signs_in("user_A")
      session = session!("workos", "code")

      assert call(:get, feed_path(w, "project-2"), [{"cookie", session}]).status == 401
      assert call(:get, feed_path(w), [{"cookie", "bizkit_session=forged"}]).status == 401

      revoke!(w, "TaskOperatorRevokedV1", w.person_grant)
      assert call(:get, feed_path(w), [{"cookie", session}]).status == 401
    end

    test "ends when the person signs out", w do
      workos_signs_in("user_A")
      session = session!("workos", "code")
      resp = open(w, {feed_path(w), [{"cookie", session}]})
      assert {_seq, %{"changes" => []}} = next(resp)

      assert call(:post, "/auth/logout", [{"cookie", session}]).status == 204
      assert next(resp) == :done
      assert call(:get, feed_path(w), [{"cookie", session}]).status == 401
    end

    test "survives replacing the identity provider", w do
      # Signed in through WorkOS; the person's device signs a task under their grant.
      workos_signs_in("user_A")
      via_workos = session!("workos", "code")
      first = open(w, {feed_path(w), [{"cookie", via_workos}]})
      _snapshot = next(first)

      task_1 = create!(w, w.person_grant, "task-1", "project-1", w.device)
      assert tasks(next(first)) == ["task-1"]

      # The administrator binds the person's identity at another provider to
      # the same principal and unbinds the WorkOS one.
      bind([{"https://idp.test", "sub-B", w.person}])
      assert next(first) == :done
      assert call(:get, feed_path(w), [{"cookie", via_workos}]).status == 401

      # Signed in through the second provider: same principal, same grant,
      # same signing device, same history.
      via_second = session!("second", "sub-B")
      again = open(w, {feed_path(w), [{"cookie", via_second}]})
      assert tasks(next(again)) == ["task-1"]

      task_2 = create!(w, w.person_grant, "task-2", "project-1", w.device)
      assert tasks(next(again)) == ["task-2"]

      {:ok, ledger} = Log.read_all(from: task_1.global_seq)

      assert for(
               e <- ledger,
               e.type == "TaskCreatedV1",
               e.chapter_id == w.chapter,
               do: e.payload["principal_id"]
             ) ==
               [w.person, w.person]

      assert task_1.payload["authorization_event_id"] == task_2.payload["authorization_event_id"]
      assert hd(task_1.signers).pubkey == hd(task_2.signers).pubkey
    end
  end
end
