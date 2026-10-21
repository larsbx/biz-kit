defmodule BizKit.Identity.NativeTest do
  use ExUnit.Case, async: false
  alias BizKit.Identity
  alias BizKit.Identity.{Native, Principal}

  defmodule Provider do
    @behaviour BizKit.Identity.Provider
    def authorize_url(_, state, callback),
      do:
        "https://idp.test/authorize?" <> URI.encode_query(%{state: state, redirect_uri: callback})

    def authenticate(_, "good", _), do: {:ok, %{issuer: "https://idp.test", subject: "person"}}
    def authenticate(_, _, _), do: {:error, :rejected}
  end

  setup do
    env = Application.get_all_env(:biz_kit_identity)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:biz_kit_identity),
          do: Application.delete_env(:biz_kit_identity, key)

      Application.put_all_env(biz_kit_identity: env)
    end)

    principal = Principal.new_id()
    Application.put_env(:biz_kit_identity, :providers, %{"test" => {Provider, []}})

    Application.put_env(:biz_kit_identity, :bindings, [
      %{issuer: "https://idp.test", subject: "person", principal: principal}
    ])

    %{principal: principal}
  end

  defp flow do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    {:ok, flow} =
      Native.begin(
        "test",
        challenge,
        String.duplicate("s", 43),
        "https://api.test/callback",
        "com.dispatch.driver://signin"
      )

    {flow, verifier}
  end

  test "handoff uses existing revocable sessions, PKCE and single-use codes", ctx do
    {flow, verifier} = flow()
    assert {:ok, url} = Native.authorization_url(flow.id)
    assert URI.decode_query(URI.parse(url).query)["state"] == flow.id
    assert {:ok, handoff} = Native.complete(flow.id, "good")
    assert handoff.state == String.duplicate("s", 43)
    assert handoff.redirect == "com.dispatch.driver://signin"
    assert {:error, _} = Native.complete(flow.id, "good")
    assert {:error, _} = Native.exchange(handoff.code, String.duplicate("x", 43))
    assert {:ok, session} = Native.exchange(handoff.code, verifier)
    assert {:error, _} = Native.exchange(handoff.code, verifier)
    assert {:ok, %{principal: principal}} = Identity.session(session)
    assert principal == ctx.principal
    Identity.logout(session)
    assert {:error, _} = Identity.session(session)
  end

  test "unbinding and expiry invalidate the same sessions" do
    {flow, verifier} = flow()
    {:ok, handoff} = Native.complete(flow.id, "good")
    {:ok, session} = Native.exchange(handoff.code, verifier)

    assert {:error, :expired} =
             Identity.session(
               session,
               System.system_time(:millisecond) + Identity.session_ttl_ms() + 1
             )

    {flow, verifier} = flow()
    {:ok, handoff} = Native.complete(flow.id, "good")
    {:ok, session} = Native.exchange(handoff.code, verifier)
    Application.put_env(:biz_kit_identity, :bindings, [])
    assert {:error, :unbound} = Identity.session(session)
  end

  test "malformed challenges and unbound provider identities issue no session" do
    assert {:error, _} =
             Native.begin("test", "plain", "state", "https://x", "com.dispatch.driver://signin")

    {flow, _} = flow()
    assert {:error, _} = Native.complete(flow.id, "bad")
    {flow, _} = flow()
    Application.put_env(:biz_kit_identity, :bindings, [])
    assert {:error, _} = Native.complete(flow.id, "good")
  end
end
