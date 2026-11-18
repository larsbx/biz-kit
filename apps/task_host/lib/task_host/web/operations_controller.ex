defmodule TaskHost.Web.OperationsController do
  @moduledoc """
  A fresh, authorized operations snapshot. All domain state remains owned by
  the canonical ledger and its existing commands; this endpoint only reads.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias BizKit.Identity
  alias CoopSubstrate.Log
  alias TaskHost.Operations
  alias TaskHost.Web.AuthController

  def index(conn, _params) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-content-type-options", "nosniff")

    with {:ok, principal, session} <- AuthController.principal(conn),
         config = Application.get_env(:task_host, :operations, Operations.default_config()),
         {:ok, response} <- Operations.snapshot(Log.gate(), principal, config),
         # A session ended while building the response must not release it.
         {:ok, %{principal: ^principal}} <- Identity.session(session) do
      json(conn, Map.put(response, "principal", principal))
    else
      {:error, :invalid_operations_config} ->
        conn |> put_status(503) |> json(%{error: "operations_unavailable"})

      _unauthenticated ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end
end
