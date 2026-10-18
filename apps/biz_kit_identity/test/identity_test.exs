defmodule BizKit.IdentityTest do
  @moduledoc """
  Authentication is a provider's job; identity is biz-kit's. A verified
  `(issuer, subject)` reaches a principal only through an explicit binding, and
  a session lives only as long as that binding and its own lifetime.
  """
  use ExUnit.Case, async: false

  alias BizKit.Identity
  alias BizKit.Identity.{Principal, Providers.WorkOS, Resolver}

  @workos_iss "https://api.workos.com/user_management/client_test"

  defmodule Static do
    @moduledoc "A second provider: the code is the subject, under a fixed issuer."
    @behaviour BizKit.Identity.Provider

    @impl true
    def authorize_url(config, state, redirect_uri),
      do: "#{config[:url]}/authorize?state=#{state}&redirect_uri=#{redirect_uri}"

    @impl true
    def authenticate(_config, "bad", _redirect_uri), do: {:error, :rejected}

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
      "static" => {Static, url: "https://idp.test"}
    })

    principal = Principal.new_id()
    bind([{@workos_iss, "user_A", principal}])
    %{principal: principal}
  end

  defp bind(bindings) do
    Application.put_env(
      :biz_kit_identity,
      :bindings,
      for({iss, sub, p} <- bindings, do: %{issuer: iss, subject: sub, principal: p})
    )
  end

  defp workos_user(id) do
    Req.Test.stub(WorkOS, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path == "/user_management/authenticate"

      assert %{"grant_type" => "authorization_code", "client_secret" => "sk_test"} =
               Jason.decode!(body)

      Req.Test.json(conn, %{
        "user" => %{"id" => id, "email" => "a@example.com"},
        "access_token" => "x"
      })
    end)
  end

  describe "principals" do
    test "are biz-kit's own IDs, not a provider's" do
      id = Principal.new_id()
      assert id =~ ~r/^prn_[a-z2-7]{26}$/
      assert Principal.valid?(id)
      refute Principal.valid?("user_01HXYZ")
      refute id == Principal.new_id()
    end
  end

  describe "WorkOS" do
    test "sends the browser to AuthKit with the state and return address" do
      {:ok, url} =
        Identity.authorize_url("workos", "st4te", "https://app.test/auth/workos/callback")

      uri = URI.parse(url)

      assert {uri.host, uri.path} == {"api.workos.com", "/user_management/authorize"}

      assert %{
               "client_id" => "client_test",
               "response_type" => "code",
               "provider" => "authkit",
               "state" => "st4te",
               "redirect_uri" => "https://app.test/auth/workos/callback"
             } = URI.decode_query(uri.query)
    end

    test "an unknown provider has no sign-in page" do
      assert Identity.authorize_url("nope", "s", "https://x") == {:error, :unknown_provider}
    end

    test "turns a code into the issuer and subject it verified" do
      workos_user("user_A")

      assert WorkOS.authenticate(Identity.provider_config("workos"), "code", "https://x") ==
               {:ok, %{issuer: @workos_iss, subject: "user_A"}}
    end

    test "a refused code is refused" do
      Req.Test.stub(WorkOS, &Plug.Conn.send_resp(&1, 400, ~s({"error":"invalid_grant"})))

      assert {:error, {:provider, 400}} =
               WorkOS.authenticate(Identity.provider_config("workos"), "code", "https://x")
    end
  end

  describe "the resolver" do
    test "maps a bound issuer and subject to its principal", %{principal: p} do
      assert Resolver.resolve(%{issuer: @workos_iss, subject: "user_A"}) == {:ok, p}
    end

    test "never matches on anything else" do
      assert Resolver.resolve(%{issuer: @workos_iss, subject: "user_B"}) == {:error, :unbound}

      assert Resolver.resolve(%{issuer: "https://evil.test", subject: "user_A"}) ==
               {:error, :unbound}
    end

    test "refuses malformed bindings rather than guessing", %{principal: p} do
      for bad <- [
            [{@workos_iss, "user_A", "alice"}],
            [{@workos_iss, "user_A", p}, {@workos_iss, "user_A", Principal.new_id()}],
            [{"", "user_A", p}]
          ] do
        bind(bad)
        assert {:error, {:invalid_bindings, _}} = Resolver.check()

        assert {:error, {:invalid_bindings, _}} =
                 Resolver.resolve(%{issuer: @workos_iss, subject: "user_A"})
      end
    end

    test "one principal may have several bound identities", %{principal: p} do
      bind([{@workos_iss, "user_A", p}, {"https://idp.test", "sub-B", p}])
      assert Resolver.resolve(%{issuer: "https://idp.test", subject: "sub-B"}) == {:ok, p}
    end
  end

  describe "sessions" do
    test "a login yields a session for the bound principal", %{principal: p} do
      workos_user("user_A")

      assert {:ok, id} = Identity.login("workos", "code", "https://x")

      assert {:ok, %{principal: ^p, identity: %{issuer: @workos_iss, subject: "user_A"}}} =
               Identity.session(id)
    end

    test "an unbound or refused identity gets none" do
      workos_user("user_B")
      assert Identity.login("workos", "code", "https://x") == {:error, :unbound}
      assert Identity.login("static", "bad", "https://x") == {:error, :rejected}
      assert Identity.login("nope", "code", "https://x") == {:error, :unknown_provider}
    end

    test "end on logout, at expiry, and when the binding goes", %{principal: p} do
      workos_user("user_A")

      {:ok, a} = Identity.login("workos", "code", "https://x")
      :ok = Identity.logout(a)
      assert Identity.session(a) == {:error, :unknown_session}

      {:ok, b} = Identity.login("workos", "code", "https://x")

      assert {:ok, _} =
               Identity.session(
                 b,
                 System.system_time(:millisecond) + Identity.session_ttl_ms() - 1
               )

      assert Identity.session(b, System.system_time(:millisecond) + Identity.session_ttl_ms() + 1) ==
               {:error, :expired}

      {:ok, c} = Identity.login("workos", "code", "https://x")
      bind([{"https://idp.test", "sub-B", p}])
      assert Identity.session(c) == {:error, :unbound}
    end

    test "all of a principal's sessions can be revoked at once", %{principal: p} do
      workos_user("user_A")
      {:ok, a} = Identity.login("workos", "code", "https://x")
      {:ok, b} = Identity.login("workos", "code", "https://x")

      :ok = Identity.revoke_principal(p)
      assert Identity.session(a) == {:error, :unknown_session}
      assert Identity.session(b) == {:error, :unknown_session}
    end

    test "changing provider keeps the principal", %{principal: p} do
      workos_user("user_A")
      {:ok, before} = Identity.login("workos", "code", "https://x")

      bind([{"https://idp.test", "sub-B", p}])
      {:ok, after_switch} = Identity.login("static", "sub-B", "https://x")

      assert Identity.session(before) == {:error, :unbound}
      assert {:ok, %{principal: ^p}} = Identity.session(after_switch)
    end
  end
end
