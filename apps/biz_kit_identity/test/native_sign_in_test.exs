defmodule BizKit.Identity.NativeSignInTest do
  @moduledoc """
  Sign-in for native apps (docs/architecture/2026-10-21-native-sign-in.md):
  RFC 8252 with PKCE, brokered by biz-kit. The app proves, at the exchange,
  that it is the one that started the sign-in; nothing else that can receive
  the redirect can turn the code into a session.
  """
  use ExUnit.Case, async: false

  alias BizKit.Identity
  alias BizKit.Identity.{NativeLogins, Principal}

  @app "com.dispatch.driver:/oauth2redirect"

  defmodule Static do
    @moduledoc "The code is the subject, under a fixed issuer."
    @behaviour BizKit.Identity.Provider

    @impl true
    def authorize_url(config, state, _redirect_uri),
      do: "#{config[:url]}/authorize?state=#{state}"

    @impl true
    def authenticate(_config, "bad", _redirect_uri), do: {:error, :rejected}

    def authenticate(config, code, _redirect_uri),
      do: {:ok, %{issuer: config[:url], subject: code}}
  end

  setup do
    env = Application.get_all_env(:biz_kit_identity)

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(:biz_kit_identity),
          not Keyword.has_key?(env, key),
          do: Application.delete_env(:biz_kit_identity, key)

      Application.put_all_env(biz_kit_identity: env)
    end)

    principal = Principal.new_id()

    Application.put_env(:biz_kit_identity, :providers, %{
      "static" => {Static, url: "https://idp.test"},
      "other" => {Static, url: "https://other.test"}
    })

    Application.put_env(:biz_kit_identity, :native_redirect_uris, [@app])

    Application.put_env(:biz_kit_identity, :bindings, [
      %{issuer: "https://idp.test", subject: "alice", principal: principal}
    ])

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    %{principal: principal, verifier: verifier, challenge: challenge}
  end

  defp code_from(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp signed_in(ctx, subject \\ "alice") do
    {:ok, request} = Identity.native_begin("static", @app, ctx.challenge, "S256", "app-state")
    {:ok, url} = Identity.native_complete("static", request, subject, "https://biz.test/cb")
    code_from(url)
  end

  test "a native sign-in ends in a session for the bound principal", ctx do
    %{"code" => code, "state" => "app-state"} = signed_in(ctx)

    assert {:ok, session, ttl} = Identity.native_exchange(code, ctx.verifier, @app)
    assert ttl == div(Identity.session_ttl_ms(), 1000)
    assert {:ok, %{principal: principal}} = Identity.session(session)
    assert principal == ctx.principal
  end

  test "the redirect carries the code back to the app, with the app's own state", ctx do
    {:ok, request} = Identity.native_begin("static", @app, ctx.challenge, "S256", "xyz")
    assert Identity.native_request?(request)

    {:ok, url} = Identity.native_complete("static", request, "alice", "https://biz.test/cb")

    assert String.starts_with?(url, @app <> "?")
    assert %{"code" => _, "state" => "xyz"} = code_from(url)
    refute Identity.native_request?(request)
  end

  test "the request is checked before anything is stored", ctx do
    assert {:error, :redirect_not_allowed} =
             Identity.native_begin("static", "evil.app:/cb", ctx.challenge, "S256", nil)

    assert {:error, :unsupported_challenge_method} =
             Identity.native_begin("static", @app, ctx.verifier, "plain", nil)

    assert {:error, :invalid_challenge} =
             Identity.native_begin("static", @app, "short", "S256", nil)

    assert {:error, :invalid_state} =
             Identity.native_begin(
               "static",
               @app,
               ctx.challenge,
               "S256",
               String.duplicate("s", 513)
             )

    assert {:error, :unknown_provider} =
             Identity.native_begin("nope", @app, ctx.challenge, "S256", nil)
  end

  test "a code is useless without the verifier that started the sign-in", ctx do
    %{"code" => code} = signed_in(ctx)
    other = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    assert {:error, :invalid_grant} = Identity.native_exchange(code, other, @app)
    # Spent by the failed attempt: the right verifier is now too late.
    assert {:error, :invalid_grant} = Identity.native_exchange(code, ctx.verifier, @app)
  end

  test "a code is spent once, and only at the redirect it was issued for", ctx do
    %{"code" => code} = signed_in(ctx)

    assert {:error, :invalid_grant} =
             Identity.native_exchange(code, ctx.verifier, "other.app:/cb")

    %{"code" => code} = signed_in(ctx)
    assert {:ok, _session, _ttl} = Identity.native_exchange(code, ctx.verifier, @app)
    assert {:error, :invalid_grant} = Identity.native_exchange(code, ctx.verifier, @app)

    assert {:error, :invalid_grant} = Identity.native_exchange("made-up", ctx.verifier, @app)
  end

  test "an unbound or refused sign-in is denied to the app, without a code", ctx do
    {:ok, request} = Identity.native_begin("static", @app, ctx.challenge, "S256", "s")
    assert {:denied, url, :unbound} = Identity.native_complete("static", request, "mallory", "cb")
    assert %{"error" => "access_denied", "state" => "s"} = code_from(url)
    refute Map.has_key?(code_from(url), "code")

    {:ok, request} = Identity.native_begin("static", @app, ctx.challenge, "S256", nil)
    assert {:denied, _url, :rejected} = Identity.native_complete("static", request, "bad", "cb")
  end

  test "a cancelled or refused sign-in, with no code at all, is still denied to the app", ctx do
    {:ok, request} = Identity.native_begin("static", @app, ctx.challenge, "S256", "s")

    assert {:denied, url, :no_code} = Identity.native_complete("static", request, nil, "cb")
    assert %{"error" => "access_denied", "state" => "s"} = code_from(url)
    refute Identity.native_request?(request)
  end

  test "a request completes once, and only through the provider it began with", ctx do
    {:ok, request} = Identity.native_begin("static", @app, ctx.challenge, "S256", nil)
    assert {:error, :unknown_request} = Identity.native_complete("other", request, "alice", "cb")
    # Spent: a request is single use even when completed wrongly.
    assert {:error, :unknown_request} = Identity.native_complete("static", request, "alice", "cb")

    assert {:error, :unknown_request} =
             Identity.native_complete("static", "made-up", "alice", "cb")
  end

  test "unbinding between sign-in and exchange yields no session", ctx do
    %{"code" => code} = signed_in(ctx)
    Application.put_env(:biz_kit_identity, :bindings, [])

    assert {:error, :invalid_grant} = Identity.native_exchange(code, ctx.verifier, @app)
  end

  test "the PKCE check is RFC 7636's S256" do
    # RFC 7636 Appendix B.
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    assert NativeLogins.verifies?(verifier, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    refute NativeLogins.verifies?(verifier, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cN")
    refute NativeLogins.verifies?("too-short", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  end
end
