defmodule EatsbotWeb.DependencySecurityTest do
  use EatsbotWeb.ConnCase, async: true

  test "an anonymous GraphQL request cannot initialize a delivery", %{conn: conn} do
    query =
      "mutation { initDelivery(input: { toName: \"unauthorized\", toLatitude: 1.0, toLongitude: 1.0, toAddress: \"fixture\" }) { result { id } errors { message } } }"

    response = conn |> post(~p"/gql", %{query: query}) |> json_response(200)
    errors = response["errors"] || get_in(response, ["data", "initDelivery", "errors"]) || []
    assert is_list(errors) and errors != []
    assert Enum.any?(errors, &(String.downcase(&1["message"]) =~ "forbidden"))
    refute get_in(response, ["data", "initDelivery", "result"])
  end

  test "malformed bearer credentials cannot grant GraphQL mutation access", %{conn: conn} do
    query =
      "mutation { initDelivery(input: { toLatitude: 1.0, toLongitude: 1.0, toAddress: \"fixture\" }) { result { id } errors { message } } }"

    response =
      conn
      |> put_req_header("authorization", "Bearer invalid.jwt.token")
      |> post(~p"/gql", %{query: query})
      |> json_response(200)

    assert [%{"message" => "forbidden"}] = get_in(response, ["data", "initDelivery", "errors"])
    refute get_in(response, ["data", "initDelivery", "result"])
  end

  test "public delivery credentials cannot disclose authentication keys", %{conn: conn} do
    delivery = EatsbotCore.Deliveries.Delivery.empty!(authorize?: false)

    query =
      "query { getDelivery(id: \"#{delivery.id}\") { id privateAuthKey publicAuthKey } }"

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> delivery.public_auth_key)
      |> post(~p"/gql", %{query: query})
      |> json_response(200)

    assert get_in(response, ["data", "getDelivery", "id"]) == delivery.id
    refute get_in(response, ["data", "getDelivery", "privateAuthKey"])
    refute get_in(response, ["data", "getDelivery", "publicAuthKey"])
  end

  test "GraphQL rejects an excessive operation before resolving its fields", %{conn: conn} do
    fields =
      Enum.map_join(1..1_001, " ", fn i ->
        "d#{i}: getDelivery(id: \"00000000-0000-0000-0000-000000000000\") { id }"
      end)

    conn = post(conn, ~p"/gql", %{query: "query { #{fields} }"})
    assert conn.status in [200, 400]
    response = Jason.decode!(conn.resp_body)
    assert Enum.any?(response["errors"], &(String.downcase(&1["message"]) =~ "complex"))
    refute response["data"]
  end

  test "delivery credentials cannot read another delivery", %{conn: conn} do
    own = EatsbotCore.Deliveries.Delivery.empty!(authorize?: false)
    other = EatsbotCore.Deliveries.Delivery.empty!(authorize?: false)

    query =
      "query { own: getDelivery(id: \"#{own.id}\") { id } other: getDelivery(id: \"#{other.id}\") { id } }"

    Enum.each([own.public_auth_key, own.private_auth_key], fn token ->
      response =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post(~p"/gql", %{query: query})
        |> json_response(200)

      assert get_in(response, ["data", "own", "id"]) == own.id
      refute get_in(response, ["data", "other"])
    end)
  end

  test "private delivery credentials cannot change another delivery", %{conn: conn} do
    own = EatsbotCore.Deliveries.Delivery.empty!(authorize?: false)

    other =
      EatsbotCore.Deliveries.Delivery.empty!(authorize?: false)
      |> EatsbotCore.Deliveries.Delivery.update_state!(:In_Preparation, authorize?: false)
      |> EatsbotCore.Deliveries.Delivery.update_state!(:Ready_To_Pickup, authorize?: false)
      |> EatsbotCore.Deliveries.Delivery.update_state!(:In_Delivery, authorize?: false)

    query =
      "mutation { updateLocation(id: \"#{other.id}\", input: { currentLatitude: 12.0, currentLongitude: 34.0 }) { result { id } errors { message } } }"

    response =
      conn
      |> put_req_header("authorization", "Bearer " <> own.private_auth_key)
      |> post(~p"/gql", %{query: query})
      |> json_response(200)

    refute get_in(response, ["data", "updateLocation", "result"])
    assert [_ | _] = get_in(response, ["data", "updateLocation", "errors"])

    persisted = Ash.get!(EatsbotCore.Deliveries.Delivery, other.id, authorize?: false)
    assert persisted.current_latitude == other.current_latitude
    assert persisted.current_longitude == other.current_longitude
  end

  test "unknown filter names produce validation errors", %{conn: conn} do
    query =
      "query { getAvailableProducts(filter: { unknownDependencyFilter: true }) { id } }"

    conn = post(conn, ~p"/gql", %{query: query})
    assert conn.status in [200, 400]
    response = Jason.decode!(conn.resp_body)
    assert is_list(response["errors"]) and response["errors"] != []
    refute response["data"]
  end

  test "negative pagination limits produce structured errors", %{conn: conn} do
    conn = post(conn, ~p"/gql", %{query: "query { getAvailableProducts(limit: -1) { id } }"})
    assert conn.status in [200, 400]
    response = Jason.decode!(conn.resp_body)
    assert is_list(response["errors"]) and response["errors"] != []
    refute get_in(response, ["data", "getAvailableProducts"])
  end

  test "the admin entry point rejects requests without its credentials", %{conn: conn} do
    assert conn |> get(~p"/admin") |> response(401)
  end

  test "an unrelated cookie cannot grant access to the admin entry point", %{conn: conn} do
    conn =
      conn
      |> put_req_header("cookie", "shadow_actor=admin; unrelated_user=admin")
      |> get(~p"/admin")

    assert response(conn, 401)
  end

  test "Ash Admin copies only its supported cookies into the LiveView session", %{conn: conn} do
    conn =
      conn
      |> put_req_header("cookie", "tenant=test; shadow_actor=admin; unrelated_user=admin")
      |> fetch_cookies()

    session = AshAdmin.Router.__session__(conn, %{"prefix" => "/admin"}, [])
    assert session["tenant"] == "test"
    refute Map.has_key?(session, "shadow_actor")
    refute Map.has_key?(session, "unrelated_user")
  end

  test "signing out requires confirmation and revokes the browser token", %{conn: conn} do
    conn = admin_session(conn)
    token = get_session(conn, "user_token")
    conn = get(conn, ~p"/sign-out")

    assert html_response(conn, 200) =~ "Sign out"
    assert get_session(conn, "user_token") == token

    [csrf_token] =
      conn.resp_body
      |> LazyHTML.from_document()
      |> LazyHTML.query("form[action='/sign-out'] input[name='_csrf_token']")
      |> LazyHTML.attribute("value")

    conn =
      conn
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> delete(~p"/sign-out", %{"_csrf_token" => csrf_token})

    assert redirected_to(conn) == "/"
    refute get_session(conn, "user_token")

    assert :error =
             AshAuthentication.Plug.Helpers.authenticate_resource_from_session(
               Eatsbot.Accounts.User,
               %{"user_token" => token},
               :eatsbot,
               []
             )
  end

  test "opening the email link requires confirmation and does not consume the token", %{
    conn: conn
  } do
    user =
      Ash.create!(Eatsbot.Accounts.User, %{email: "magic-link@example.com"}, authorize?: false)

    strategy = AshAuthentication.Info.strategy!(Eatsbot.Accounts.User, :magic_link)
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)

    conn = get(conn, ~p"/auth/user/magic_link?token=#{token}")
    assert html_response(conn, 200) =~ "Sign in"
    refute get_session(conn, "user_token")

    assert {:ok, claims, _resource} = AshAuthentication.Jwt.verify(token, :eatsbot)

    assert {:ok, [_]} =
             AshAuthentication.TokenResource.Actions.get_token(
               Eatsbot.Accounts.Token,
               %{"jti" => claims["jti"], "purpose" => "magic_link"}
             )
  end
end
