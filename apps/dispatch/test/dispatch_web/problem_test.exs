defmodule DispatchWeb.ProblemTest do
  @moduledoc """
  Section 19.2 fixes the shape of every error response. The fields are easy to
  get almost right — a missing `correlation_id` or a `type` that does not match
  the `code` degrades silently, because a rejection still *looks* like a
  rejection to a client that only reads the status.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias DispatchWeb.Problem

  defp problem(status, code, detail, opts \\ []) do
    conn =
      :post
      |> conn(Keyword.get(opts, :path, "/v1/me/status-events"))
      |> then(fn conn ->
        case Keyword.get(opts, :correlation_id, "corr-1") do
          nil -> conn
          id -> assign(conn, :correlation_id, id)
        end
      end)
      |> Problem.send(status, code, detail)

    {conn, Jason.decode!(conn.resp_body)}
  end

  test "carries every field Section 19.2 requires" do
    {_conn, body} = problem(403, "FORBIDDEN", "Not permitted.")

    for field <- ~w(type title status detail instance code correlation_id) do
      assert Map.has_key?(body, field), "missing #{field}"
    end

    assert body["status"] == 403
    assert body["title"] == "Forbidden"
    assert body["code"] == "FORBIDDEN"
    assert body["detail"] == "Not permitted."
    assert body["instance"] == "/v1/me/status-events"
    assert body["correlation_id"] == "corr-1"
  end

  test "the type URI is derived from the code, so the two cannot disagree" do
    {_conn, body} = problem(409, "IDEMPOTENCY_KEY_REUSED", "Reused.")

    assert body["type"] == "https://dispatch.invalid/problems/idempotency-key-reused"
  end

  test "is sent as application/problem+json and never cached" do
    {conn, _body} = problem(401, "UNAUTHENTICATED", "No token.")

    assert get_resp_header(conn, "content-type") == ["application/problem+json; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "halts the connection, so a pipeline cannot continue past a rejection" do
    {conn, _body} = problem(401, "UNAUTHENTICATED", "No token.")

    assert conn.halted
  end

  test "reports an unassigned correlation ID rather than omitting the field" do
    {_conn, body} = problem(400, "MALFORMED_REQUEST", "Bad.", correlation_id: nil)

    assert body["correlation_id"] == "unassigned"
  end
end
