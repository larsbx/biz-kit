defmodule SpruceGoose.Web.TaskController do
  @moduledoc """
  Governance cancels a task (docs/architecture/2026-10-19-cancel-reopen.md),
  signed with a governance key by whoever holds it, an administrator's
  browser or a script.

      GET  /api/v1/chapters/:c/tenants/:t/projects/:p/tasks/:task_id
           → {task_id, title, state, version}
      POST …/tasks/:task_id/cancellation            {"governance_key_id", "reason"}
           → 201 the cancellation to sign
      POST …/tasks/:task_id/cancellation/:held_id   {"signature"} → 201 {event_id, global_seq}

  The first two are signed by a governance key (`Governance.Read`) and
  answer only for the chapters it governs. Nothing here cancels anything
  without a governance signature; the server signs nothing.
  """

  use Phoenix.Controller, formats: [:json]

  import SpruceGoose.Web.Requests

  alias CoopSubstrate.Cancellation

  def show(conn, %{"task_id" => id} = params) do
    with {:ok, chapters} <- governance_read(conn),
         {:ok, task} <- Cancellation.fetch(key(params), chapters) do
      json(conn, Map.put(task, :task_id, id))
    else
      {:unauthorized, reason} -> unauthorized(conn, reason)
      error -> refuse(conn, error)
    end
  end

  def prepare(conn, %{"chapter_id" => chapter} = params) do
    with {:ok, chapters} <- governance_read(conn),
         true <- chapter in chapters or {:unauthorized, :not_governance},
         {:ok, body} <- json_body(conn),
         {:ok, key_id} <- string(body["governance_key_id"]),
         {:ok, reason} <- string(body["reason"]),
         {:ok, pending} <- Cancellation.prepare(key(params), reason, key_id) do
      held(conn, pending)
    else
      {:unauthorized, reason} -> unauthorized(conn, reason)
      error -> refuse(conn, error)
    end
  end

  def cancel(conn, %{"held_id" => held_id} = params) do
    with {:ok, body} <- json_body(conn),
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, env} <- Cancellation.cancel(key(params), held_id, signature) do
      appended(conn, env)
    else
      error -> refuse(conn, error)
    end
  end

  defp key(%{"chapter_id" => c, "tenant_id" => t, "project_id" => p, "task_id" => id}),
    do: {c, t, p, id}
end
