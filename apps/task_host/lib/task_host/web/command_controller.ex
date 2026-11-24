defmodule TaskHost.Web.CommandController do
  @moduledoc """
  A person's decision on a suggestion (docs/architecture/2026-10-18-decide.md)
  or lifecycle step (docs/architecture/2026-10-19-lifecycle.md,
  2026-10-19-execution.md), signed on their device. Transport only: `CoopSubstrate.Commands`
  prepares and admits the command; the ledger checks it as any operator
  command.

      POST /api/v1/chapters/:c/tenants/:t/projects/:p/commands
           {"decision": "accept" | "amend" | "decline", "suggestion_event_id", "key_id",
            "edits"? (amend: the fields the person changed), "reason"? (decline)}
        or {"action": "propose" | "queue", "task_id", "key_id"}
           {"action": "acknowledge_sop", "task_id", "custody_receipt_id", "key_id"}
           {"action": "ready", "task_id", "custody_receipts": {name: receipt id}, "key_id"}
           {"action": "revoke_delegation", "delegation_event_id", "key_id"}
           {"action": "record_custody", "artifact_digest": hex SHA-256, "key_id"}
           {"action": "attest_artifact", "task_id", "name", "custody_receipt_id",
            "artifact_digest": hex SHA-256, "size_bytes", "repository", "commit",
            "tree", "path", "key_id"} (independent reviewer device)
           {"action": "start", "task_id", "key_id"}
           {"action": "submit_evidence", "task_id", "custody_receipts": {criterion: receipt id}, "key_id"}
           {"action": "review", "task_id", "decision": "accept" | "refuse", "reason", "key_id"}
             (signed with a reviewer device's key)
           {"action": "complete", "task_id", "review_event_id", "key_id"}
           {"action": "cancel" | "reopen", "task_id", "reason", "key_id"}
           {"action": "instantiate", "revision_event_id", "roadmap_key", "workflow_id",
            "task_ids": {definition id: new task id}, "key_id"}
           {"action": "add_todo" | "revise_todo", "task_id", "todo_id", "title",
            "depends_on": [todo id], "key_id", "expected_todo_version"? (revise only)}
           {"action": "complete_todo", "task_id", "todo_id", "key_id"}
           {"action": "drop_todo", "task_id", "todo_id", "reason", "key_id"}
             (docs/architecture/2026-10-20-sprucegoose-salvage.md)
           → 201 {id, type, payload, signing_bytes (base64url), expires_at}
      POST /api/v1/commands/:id  {"signature": base64url}
           → 201 {event_id, global_seq}

  Both need a browser session cookie or a native bearer session. When given,
  `grant_event_id` selects the exact active grant. The endpoints only accept
  `application/json`: a
  cross-site form cannot send it, and SameSite=Lax keeps the cookie off
  cross-site POSTs anyway. The device must sign the bytes it was given; the
  server holds no key.

  When editing dependencies read from the feed, send the TODO version from
  that read. The ledger rejects an older version before signing and at append.
  """

  use Phoenix.Controller, formats: [:json]

  import TaskHost.Web.Requests

  alias CoopSubstrate.{Commands, ULID}
  alias TaskHost.Web.AuthController

  def prepare(conn, %{"chapter_id" => c, "tenant_id" => t, "project_id" => p}) do
    with {:ok, principal, _session} <- AuthController.operator_principal(conn),
         {:ok, body} <- json_body(conn),
         {:ok, decision} <- command(body),
         {:ok, key_id} <- string(body["key_id"]),
         {:ok, grant} <- requested_grant(body),
         {:ok, pending} <- Commands.prepare(principal, key_id, {c, t, p}, decision, grant) do
      held(conn, pending)
    else
      error -> refuse(conn, error)
    end
  end

  def submit(conn, %{"id" => id}) do
    with {:ok, principal, _session} <- AuthController.operator_principal(conn),
         {:ok, body} <- json_body(conn),
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, env} <- Commands.submit(principal, id, signature) do
      appended(conn, env)
    else
      error -> refuse(conn, error)
    end
  end

  defp requested_grant(body) do
    case Map.fetch(body, "grant_event_id") do
      :error -> {:ok, nil}
      {:ok, id} -> if(ULID.valid?(id), do: {:ok, id}, else: {:error, :bad_request})
    end
  end

  # The actions named by string in a request, as atoms fixed at compile time:
  # nothing a request sends becomes an atom, and no action depends on which
  # modules happen to be loaded.
  @actions Map.new(
             ~w(propose queue start ready submit_evidence cancel reopen add_todo revise_todo),
             &{&1, String.to_atom(&1)}
           )

  defp command(%{"action" => _} = body), do: action(body)
  defp command(body), do: decision(body)

  defp action(%{"action" => a, "task_id" => t})
       when a in ~w(propose queue start) and is_binary(t),
       do: {:ok, {@actions[a], t}}

  defp action(%{"action" => "acknowledge_sop", "task_id" => t, "custody_receipt_id" => r})
       when is_binary(t) and is_binary(r),
       do: {:ok, {:acknowledge_sop, t, r}}

  defp action(%{"action" => a, "task_id" => t, "custody_receipts" => rs})
       when a in ~w(ready submit_evidence) and is_binary(t) and is_map(rs) do
    if Enum.all?(rs, fn {_, id} -> is_binary(id) end),
      do: {:ok, {@actions[a], t, rs}},
      else: {:error, :bad_action}
  end

  defp action(%{"action" => "review", "task_id" => t, "decision" => d, "reason" => r})
       when is_binary(t) and is_binary(d) and is_binary(r),
       do: {:ok, {:review, t, d, r}}

  defp action(%{"action" => a, "task_id" => t, "reason" => r})
       when a in ~w(cancel reopen) and is_binary(t) and is_binary(r),
       do: {:ok, {@actions[a], t, r}}

  defp action(%{"action" => "complete", "task_id" => t, "review_event_id" => r})
       when is_binary(t) and is_binary(r),
       do: {:ok, {:complete, t, r}}

  defp action(%{"action" => "revoke_delegation", "delegation_event_id" => d}) when is_binary(d),
    do: {:ok, {:revoke_delegation, d}}

  defp action(%{"action" => "record_custody", "artifact_digest" => hex}) when is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, <<_::256>> = digest} -> {:ok, {:record_custody, digest}}
      _ -> {:error, :bad_action}
    end
  end

  defp action(
         %{
           "action" => "attest_artifact",
           "task_id" => task,
           "artifact_digest" => hex,
           "size_bytes" => size
         } = body
       )
       when is_binary(task) and is_binary(hex) and is_integer(size) and size >= 0 do
    names = ~w(name custody_receipt_id repository commit tree path)

    with true <- Enum.all?(names, &is_binary(body[&1])),
         {:ok, <<_::256>> = digest} <- Base.decode16(hex, case: :lower) do
      fields =
        body
        |> Map.take(names)
        |> Map.merge(%{"artifact_digest" => {:bytes, digest}, "size_bytes" => size})

      {:ok, {:attest_artifact, task, fields}}
    else
      _ -> {:error, :bad_action}
    end
  end

  defp action(%{
         "action" => "instantiate",
         "revision_event_id" => rev,
         "roadmap_key" => roadmap,
         "workflow_id" => workflow,
         "task_ids" => ids
       })
       when is_binary(rev) and is_binary(roadmap) and is_binary(workflow) and is_map(ids) do
    if Enum.all?(ids, fn {_, id} -> is_binary(id) end),
      do: {:ok, {:instantiate, rev, roadmap, workflow, ids}},
      else: {:error, :bad_action}
  end

  defp action(
         %{
           "action" => a,
           "task_id" => t,
           "todo_id" => todo,
           "title" => title,
           "depends_on" => deps
         } = body
       )
       when a in ~w(add_todo revise_todo) and is_binary(t) and is_binary(todo) and
              is_binary(title) and is_list(deps) do
    with true <- Enum.all?(deps, &is_binary/1) do
      case Map.fetch(body, "expected_todo_version") do
        :error ->
          {:ok, {@actions[a], t, todo, title, deps}}

        {:ok, v} when a == "revise_todo" and is_integer(v) and v > 0 ->
          {:ok, {:revise_todo, t, todo, title, deps, v}}

        _ ->
          {:error, :bad_action}
      end
    else
      false -> {:error, :bad_action}
    end
  end

  defp action(%{"action" => "complete_todo", "task_id" => t, "todo_id" => todo})
       when is_binary(t) and is_binary(todo),
       do: {:ok, {:complete_todo, t, todo}}

  defp action(%{"action" => "drop_todo", "task_id" => t, "todo_id" => todo, "reason" => r})
       when is_binary(t) and is_binary(todo) and is_binary(r),
       do: {:ok, {:drop_todo, t, todo, r}}

  defp action(_body), do: {:error, :bad_action}

  defp decision(%{"decision" => "accept", "suggestion_event_id" => id}) when is_binary(id),
    do: {:ok, {:accept, id}}

  defp decision(%{"decision" => "amend", "suggestion_event_id" => id, "edits" => edits})
       when is_binary(id) and is_map(edits),
       do: {:ok, {:amend, id, edits}}

  defp decision(%{"decision" => "decline", "suggestion_event_id" => id, "reason" => r})
       when is_binary(id) and is_binary(r),
       do: {:ok, {:decline, id, r}}

  defp decision(_body), do: {:error, :bad_decision}
end
