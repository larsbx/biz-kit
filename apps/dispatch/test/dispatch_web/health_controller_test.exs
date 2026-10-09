defmodule DispatchWeb.HealthControllerTest do
  @moduledoc """
  Section 32 defines the three health endpoints and Section 19.2 requires every
  error response to be an RFC 9457 problem carrying a correlation ID. The
  correlation-ID assertion is here because it is exactly the kind of detail that
  silently degrades: a misspelled plug option leaves the field present but
  permanently unassigned, which no smoke test would notice.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  @opts DispatchWeb.Router.init([])

  defp call(method, path, headers \\ []) do
    conn =
      method
      |> conn(path)
      |> Plug.RequestId.call(Plug.RequestId.init(assign_as: :correlation_id))

    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> DispatchWeb.Router.call(@opts)
  end

  describe "liveness" do
    test "reports the process is running and is never cached" do
      conn = call(:get, "/health/live")

      assert conn.status == 200
      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end
  end

  describe "the diagnostic endpoint" do
    test "denies an unauthenticated request" do
      conn = call(:get, "/health/dependencies")

      assert conn.status == 401
      assert hd(get_resp_header(conn, "content-type")) =~ "application/problem+json"
    end

    test "denies a wrong token without revealing which precondition failed" do
      wrong =
        call(:get, "/health/dependencies", [
          {"authorization", "Bearer " <> String.duplicate("x", 64)}
        ])

      missing = call(:get, "/health/dependencies")

      assert wrong.status == missing.status

      assert Jason.decode!(wrong.resp_body)["detail"] ==
               Jason.decode!(missing.resp_body)["detail"]
    end

    test "the problem carries every RFC 9457 field with a real correlation ID" do
      conn = call(:get, "/health/dependencies")
      problem = Jason.decode!(conn.resp_body)

      for field <- ~w(type title status detail instance code correlation_id) do
        assert Map.has_key?(problem, field), "missing #{field}"
      end

      assert problem["correlation_id"] != "unassigned"
      assert problem["correlation_id"] == conn.assigns.correlation_id
    end

    test "accepts the configured token and reports presence, never a value" do
      token = Application.get_env(:dispatch, :diagnostics_token)
      conn = call(:get, "/health/dependencies", [{"authorization", "Bearer " <> token}])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      # Section 31: configuration keys and redacted presence only.
      for {_name, present} <- body["adapters"]["required_secrets"] do
        assert is_boolean(present)
      end

      refute conn.resp_body =~ token
    end
  end
end
