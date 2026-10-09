defmodule Eatsbot.AuthenticationDependencyTest do
  use Eatsbot.DataCase, async: true

  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers
  alias AshAuthentication.TokenResource.Actions
  alias Eatsbot.Accounts.{Token, User}

  setup do
    user = Ash.create!(User, %{email: "dependency-security@example.com"}, authorize?: false)
    {:ok, user: user}
  end

  test "revoked authentication tokens cannot be used as bearer credentials", %{user: user} do
    {:ok, token, _claims} = Jwt.token_for_user(user)
    assert bearer(token).assigns.current_user.id == user.id
    assert :ok = Actions.revoke(Token, token)
    refute bearer(token).assigns[:current_user]
  end

  test "purpose-limited tokens cannot be replayed as bearer credentials", %{user: user} do
    Enum.each(["sign_in", "remember_me", "reset", "magic_link"], fn purpose ->
      {:ok, token, _claims} = Jwt.token_for_user(user, %{"purpose" => purpose}, purpose: purpose)
      refute bearer(token).assigns[:current_user]

      # Exercise the claim check even when persistence would otherwise allow it.
      {:ok, token, claims} = Jwt.token_for_user(user, %{"purpose" => purpose})
      assert {:ok, [_]} = Actions.get_token(Token, %{"jti" => claims["jti"], "purpose" => "user"})
      refute bearer(token).assigns[:current_user]
    end)
  end

  test "an unpersisted token is rejected even when its signature is valid", %{user: user} do
    {:ok, token, claims} = Jwt.token_for_user(user)
    assert bearer(token).assigns.current_user.id == user.id
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM tokens WHERE jti = $1", [claims["jti"]])
    refute bearer(token).assigns[:current_user]
  end

  test "malformed bearer credentials do not authenticate" do
    refute bearer("invalid.jwt.token").assigns[:current_user]
  end

  test "legacy subject-only sessions require a fresh sign-in", %{user: user} do
    subject = AshAuthentication.user_to_subject(user)

    assert :error =
             Helpers.authenticate_resource_from_session(User, %{"user" => subject}, :eatsbot, [])

    refute live_session(%{"user" => subject})
  end

  test "forged revocation cannot invalidate a signed credential", %{user: user} do
    {:ok, token, _claims} = Jwt.token_for_user(user)
    [header, payload, _signature] = String.split(token, ".")
    forged = Enum.join([header, payload, Base.url_encode64("forged", padding: false)], ".")

    assert {:error, _} = Actions.revoke(Token, forged)
    assert bearer(token).assigns.current_user.id == user.id
  end

  test "clearing a session revokes both browser and bearer credentials", %{user: user} do
    {:ok, browser_token, _claims} = Jwt.token_for_user(user)
    {:ok, bearer_token, _claims} = Jwt.token_for_user(user)

    conn =
      Plug.Test.conn(:delete, "/sign-out")
      |> Plug.Test.init_test_session(%{"user_token" => browser_token})
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> bearer_token)
      |> AshAuthentication.Phoenix.Controller.clear_session(:eatsbot)

    refute Plug.Conn.get_session(conn, "user_token")
    refute bearer(browser_token).assigns[:current_user]
    refute bearer(bearer_token).assigns[:current_user]
  end

  defp bearer(token) do
    Plug.Test.conn(:get, "/")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Helpers.retrieve_from_bearer(:eatsbot)
  end

  test "revocation also invalidates browser sessions", %{user: user} do
    {:ok, token, _claims} = Jwt.token_for_user(user)
    session = %{"user_token" => token}

    assert {:ok, %{id: id}} =
             Helpers.authenticate_resource_from_session(User, session, :eatsbot, [])

    assert id == user.id
    assert :ok = Actions.revoke(Token, token)
    assert :error = Helpers.authenticate_resource_from_session(User, session, :eatsbot, [])

    refute live_session(session)
  end

  defp live_session(session) do
    {:cont, socket} =
      AshAuthentication.Phoenix.LiveSession.on_mount(
        :default,
        %{},
        session,
        %Phoenix.LiveView.Socket{endpoint: EatsbotWeb.Endpoint}
      )

    socket.assigns[:current_user]
  end

  test "sign-in renews the session while retaining the return path", %{user: user} do
    {:ok, token, _claims} = Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Test.init_test_session(%{"return_to" => "/deliveries"})
      |> Helpers.store_in_session(user)

    assert conn.private.plug_session_info == :renew
    assert Plug.Conn.get_session(conn, "user_token") == token
    assert Plug.Conn.get_session(conn, "return_to") == "/deliveries"
  end
end
