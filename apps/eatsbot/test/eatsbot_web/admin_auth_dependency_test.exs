defmodule EatsbotWeb.AdminAuthDependencyTest do
  use EatsbotWeb.ConnCase, async: false

  setup do
    previous_key = System.get_env("ADMIN_API_KEY")

    on_exit(fn ->
      if previous_key do
        System.put_env("ADMIN_API_KEY", previous_key)
      else
        System.delete_env("ADMIN_API_KEY")
      end
    end)
  end

  test "admin authentication reads the current runtime key", %{conn: conn} do
    System.put_env("ADMIN_API_KEY", "dependency-first-key")
    assert conn |> admin_request("dependency-first-key") |> response(200)
    assert {:ok, %{access_level: :admin}, nil} = delivery_credential("dependency-first-key")

    System.put_env("ADMIN_API_KEY", "dependency-rotated-key")
    assert conn |> admin_request("dependency-first-key") |> response(401)
    assert conn |> admin_request("dependency-rotated-key") |> response(200)
    assert :error = delivery_credential("dependency-first-key")
    assert {:ok, %{access_level: :admin}, nil} = delivery_credential("dependency-rotated-key")
  end

  test "missing or empty admin configuration rejects credentials", %{conn: conn} do
    System.delete_env("ADMIN_API_KEY")
    assert conn |> admin_request("") |> response(401)
    assert :error = delivery_credential("")

    System.put_env("ADMIN_API_KEY", "")
    assert conn |> admin_request("") |> response(401)
    assert :error = delivery_credential("")
  end

  defp admin_request(conn, password) do
    conn
    |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("admin", password))
    |> get(~p"/admin")
  end

  defp delivery_credential(token),
    do: EatsbotWeb.Deliveries.DeliveryAuthPlug.get_token_data(token)
end
