defmodule SpruceGoose.Web.NativeSignInTest do
  @moduledoc """
  A native app signs in through the system browser and leaves with a bearer
  session (docs/architecture/2026-10-21-native-sign-in.md): the round trip over
  HTTP, and the refusals that keep a code from working for anyone but the app
  that asked for it.
  """
  use SpruceGoose.DataCase, async: false

  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal

  require Logger

  @app "com.dispatch.driver:/oauth2redirect"

  setup do
    providers!()
    Application.put_env(:biz_kit_identity, :native_redirect_uris, [@app])
    on_exit(fn -> Application.delete_env(:biz_kit_identity, :native_redirect_uris) end)
    person = Principal.new_id()
    bind([{workos_iss(), "user_A", person}])

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    %{person: person, verifier: verifier, challenge: challenge}
  end

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  defp location(conn), do: conn |> Plug.Conn.get_resp_header("location") |> List.first()

  defp native_login(ctx, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "redirect_uri" => @app,
          "code_challenge" => ctx.challenge,
          "code_challenge_method" => "S256",
          "state" => "app-state"
        },
        overrides
      )

    call(:get, "/auth/workos/native/login?" <> URI.encode_query(params), [])
  end

  # The browser's half: login redirect, provider, callback. Returns the callback.
  defp browser_round_trip(ctx) do
    login = native_login(ctx)
    state = cookie(login, "bizkit_login_state")

    call(:get, "/auth/workos/callback?code=code&state=#{state}", [
      {"cookie", "bizkit_login_state=#{state}"}
    ])
  end

  defp token(params),
    do: call(:post, "/auth/token", [], Map.put_new(params, "grant_type", "authorization_code"))

  test "the system browser returns to the app with a code, which becomes a bearer session", ctx do
    workos_signs_in("user_A")

    login = native_login(ctx)
    assert login.status == 302
    assert location(login) =~ "https://api.workos.com/user_management/authorize?"
    assert query(location(login))["state"] == cookie(login, "bizkit_login_state")

    callback = browser_round_trip(ctx)
    assert callback.status == 302
    assert String.starts_with?(location(callback), @app <> "?")
    assert %{"code" => code, "state" => "app-state"} = query(location(callback))
    # A native sign-in does not leave a session cookie in the browser.
    refute Map.has_key?(callback.resp_cookies, "bizkit_session")

    granted = token(%{"code" => code, "code_verifier" => ctx.verifier, "redirect_uri" => @app})
    assert granted.status == 200
    assert Plug.Conn.get_resp_header(granted, "cache-control") == ["no-store"]

    # No expires_in: the session lasts until signed out.
    assert %{"access_token" => session, "token_type" => "Bearer"} =
             granted_body = Jason.decode!(granted.resp_body)

    refute Map.has_key?(granted_body, "expires_in")

    me = call(:get, "/auth/me", [{"authorization", "Bearer " <> session}])
    assert me.status == 200
    assert Jason.decode!(me.resp_body) == %{"principal" => ctx.person}

    assert call(:post, "/auth/logout", [{"authorization", "Bearer " <> session}]).status == 204
    assert call(:get, "/auth/me", [{"authorization", "Bearer " <> session}]).status == 401
  end

  test "logout confirms revocation without logging credentials and leaves other sessions live",
       ctx do
    identity = %{issuer: workos_iss(), subject: "user_A"}
    ended = BizKit.Identity.Sessions.create_native(ctx.person, identity)
    kept = BizKit.Identity.Sessions.create_native(ctx.person, identity)

    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug, format: "$message\n"], fn ->
        assert call(:post, "/auth/logout", [{"authorization", "Bearer " <> ended}]).status ==
                 204
      end)

    assert log =~ "session logout completed bearer_present=true cookie_present=false"
    refute log =~ ended
    refute log =~ kept
    refute log =~ ctx.person
    assert call(:get, "/auth/me", [{"authorization", "Bearer " <> ended}]).status == 401
    assert call(:get, "/auth/me", [{"authorization", "Bearer " <> kept}]).status == 200
    restart_sessions()
    assert call(:get, "/auth/me", [{"authorization", "Bearer " <> ended}]).status == 401
    assert call(:get, "/auth/me", [{"authorization", "Bearer " <> kept}]).status == 200
  end

  test "a native session outlives a restart, until the app signs out", ctx do
    workos_signs_in("user_A")
    %{"code" => code} = ctx |> browser_round_trip() |> location() |> query()

    %{"access_token" => session} =
      token(%{"code" => code, "code_verifier" => ctx.verifier, "redirect_uri" => @app}).resp_body
      |> Jason.decode!()

    {:ok, %{authenticated_at: signed_in}} = BizKit.Identity.session(session)
    restart_sessions()
    assert call(:get, "/auth/me", [{"authorization", "Bearer " <> session}]).status == 200
    # When it was earned comes back from Postgres too, to the millisecond.
    assert {:ok, %{authenticated_at: ^signed_in}} = BizKit.Identity.session(session)

    assert call(:post, "/auth/logout", [{"authorization", "Bearer " <> session}]).status == 204
    restart_sessions()
    assert call(:get, "/auth/me", [{"authorization", "Bearer " <> session}]).status == 401
    assert SpruceGoose.Repo.query!("SELECT count(*) FROM identity_native_sessions").rows == [[0]]
  end

  # What a restart does to the sessions held in memory.
  defp restart_sessions do
    name = BizKit.Cluster.Singleton.name(BizKit.Identity.Sessions)
    pid = GenServer.whereis(name)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    wait_until(fn -> GenServer.whereis(name) not in [nil, pid] end)
  end

  defp wait_until(check, tries \\ 100) do
    cond do
      check.() -> :ok
      tries == 0 -> flunk("the session process did not come back")
      true -> Process.sleep(10) && wait_until(check, tries - 1)
    end
  end

  test "a code is refused without the app's verifier, and is spent by the attempt", ctx do
    workos_signs_in("user_A")
    %{"code" => code} = ctx |> browser_round_trip() |> location() |> query()
    other = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    wrong = token(%{"code" => code, "code_verifier" => other, "redirect_uri" => @app})
    assert wrong.status == 400
    assert Jason.decode!(wrong.resp_body) == %{"error" => "invalid_grant"}

    assert token(%{"code" => code, "code_verifier" => ctx.verifier, "redirect_uri" => @app}).status ==
             400
  end

  test "malformed token requests are refused", ctx do
    assert token(%{
             "grant_type" => "password",
             "code" => "c",
             "code_verifier" => ctx.verifier,
             "redirect_uri" => @app
           }).status == 400

    assert token(%{"code" => "c"}).status == 400
  end

  test "an unbound person is sent back to the app denied, with no code", ctx do
    workos_signs_in("user_B")
    callback = browser_round_trip(ctx)

    assert callback.status == 302
    assert %{"error" => "access_denied", "state" => "app-state"} = query(location(callback))
    refute Map.has_key?(query(location(callback)), "code")
  end

  test "a provider refusal or a cancelled sign-in still returns the browser to the app", ctx do
    login = native_login(ctx)
    state = cookie(login, "bizkit_login_state")

    callback =
      call(:get, "/auth/workos/callback?error=access_denied&state=#{state}", [
        {"cookie", "bizkit_login_state=#{state}"}
      ])

    assert callback.status == 302
    assert %{"error" => "access_denied", "state" => "app-state"} = query(location(callback))

    # A web sign-in without a code is still refused outright.
    web = call(:get, "/auth/workos/login", [])
    web_state = cookie(web, "bizkit_login_state")

    assert call(:get, "/auth/workos/callback?error=access_denied&state=#{web_state}", [
             {"cookie", "bizkit_login_state=#{web_state}"}
           ]).status == 401
  end

  test "a refused token request logs a category, never the code or verifier", ctx do
    workos_signs_in("user_A")
    %{"code" => code} = ctx |> browser_round_trip() |> location() |> query()

    # Test config logs at :warning; this module is not async, so raising the
    # level for this one check affects no other test.
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :info, format: "$message\n"], fn ->
        assert token(%{"code" => code, "code_verifier" => ctx.verifier}).status == 400
      end)

    assert log =~ "native token refused: missing_parameters"
    refute log =~ code
    refute log =~ ctx.verifier

    # The code was not presented to an exchange, so it still works.
    assert token(%{"code" => code, "code_verifier" => ctx.verifier, "redirect_uri" => @app}).status ==
             200
  end

  test "a request that could not be honoured never redirects anywhere", ctx do
    for {overrides, reason} <- [
          {%{"redirect_uri" => "https://evil.test/cb"}, "redirect_not_allowed"},
          {%{"code_challenge_method" => "plain"}, "unsupported_challenge_method"},
          {%{"code_challenge" => "short"}, "invalid_challenge"}
        ] do
      conn = native_login(ctx, overrides)
      assert conn.status == 400
      assert Plug.Conn.get_resp_header(conn, "location") == []
      assert Jason.decode!(conn.resp_body)["reason"] == reason
    end

    assert call(:get, "/auth/nope/native/login", []).status == 404
  end

  test "a native callback still needs the browser's own state", ctx do
    workos_signs_in("user_A")
    login = native_login(ctx)
    state = cookie(login, "bizkit_login_state")

    assert call(:get, "/auth/workos/callback?code=code&state=#{state}", [
             {"cookie", "bizkit_login_state=someone-else"}
           ]).status == 401
  end

  test "a web sign-in is unchanged by the native flow" do
    workos_signs_in("user_A")
    assert %{"bizkit_session" => %{http_only: true}} = sign_in("workos", "code").resp_cookies
  end
end
