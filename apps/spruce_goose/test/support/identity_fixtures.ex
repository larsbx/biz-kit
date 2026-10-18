defmodule SpruceGoose.IdentityFixtures do
  @moduledoc """
  Sign-in for SpruceGoose's tests: WorkOS stubbed with `Req.Test`, a second
  provider whose code is the subject, bindings, and the browser's round trip
  through `/auth`.
  """

  import ExUnit.Assertions
  import SpruceGoose.LedgerFixtures, only: [call: 3]

  alias BizKit.Identity.Providers.WorkOS

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

  def workos_iss, do: "https://api.workos.com/user_management/client_test"

  @doc "Configure both providers for this test, restoring the identity config after."
  def providers! do
    env = Application.get_all_env(:biz_kit_identity)
    ExUnit.Callbacks.on_exit(fn -> Application.put_all_env(biz_kit_identity: env) end)

    Application.put_env(:biz_kit_identity, :providers, %{
      "workos" =>
        {WorkOS,
         client_id: "client_test",
         api_key: "sk_test",
         req_options: [plug: {Req.Test, WorkOS}, retry: false]},
      "second" => {SecondProvider, url: "https://idp.test"}
    })
  end

  def bind(bindings) do
    Application.put_env(
      :biz_kit_identity,
      :bindings,
      for({iss, sub, p} <- bindings, do: %{issuer: iss, subject: sub, principal: p})
    )
  end

  def workos_signs_in(user_id) do
    Req.Test.stub(WorkOS, fn conn ->
      Req.Test.json(conn, %{"user" => %{"id" => user_id}, "access_token" => "x"})
    end)
  end

  def cookie(conn, name), do: conn.resp_cookies[name][:value]

  @doc "The browser's round trip: login redirect, provider, callback. The callback response."
  def sign_in(provider, code) do
    login = call(:get, "/auth/#{provider}/login", [])
    state = cookie(login, "bizkit_login_state")

    call(:get, "/auth/#{provider}/callback?code=#{code}&state=#{state}", [
      {"cookie", "bizkit_login_state=#{state}"}
    ])
  end

  @doc "A signed-in session, as a Cookie header value."
  def session!(provider, code) do
    conn = sign_in(provider, code)
    assert conn.status == 302
    "bizkit_session=" <> cookie(conn, "bizkit_session")
  end
end
