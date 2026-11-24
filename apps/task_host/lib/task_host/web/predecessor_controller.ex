defmodule TaskHost.Web.PredecessorController do
  @moduledoc "A governance-signed edit of an ad hoc task's readiness predecessors."
  use Phoenix.Controller, formats: [:json]

  import TaskHost.Web.Requests

  alias CoopSubstrate.PredecessorChanges

  def show(conn, %{"chapter_id" => chapter} = params) do
    with :ok <- governing(conn, chapter),
         {:ok, snapshot} <- PredecessorChanges.snapshot(key(params)) do
      conn |> Plug.Conn.put_resp_header("cache-control", "no-store") |> json(snapshot)
    else
      %Plug.Conn{} = refused -> refused
      error -> refuse(conn, error)
    end
  end

  def prepare(conn, %{"chapter_id" => chapter} = params) do
    with :ok <- governing(conn, chapter),
         {:ok, body} <- json_body(conn),
         operation when operation in ~w(add remove) <- body["operation"],
         version when is_integer(version) and version > 0 <- body["expected_version"],
         {:ok, predecessor} <- string(body["predecessor_id"]),
         {:ok, key_id} <- string(body["governance_key_id"]),
         {:ok, pending} <-
           PredecessorChanges.prepare(key(params), operation, predecessor, version, key_id) do
      held(conn, pending)
    else
      %Plug.Conn{} = refused -> refused
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end

  def submit(conn, %{"held_id" => id} = params) do
    with {:ok, body} <- json_body(conn),
         {:ok, signature} when is_binary(signature) <- bytes(body["signature"]),
         {:ok, env} <- PredecessorChanges.submit(key(params), id, signature) do
      appended(conn, env)
    else
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end

  defp key(%{"chapter_id" => c, "tenant_id" => t, "project_id" => p, "task_id" => id}),
    do: {c, t, p, id}
end
