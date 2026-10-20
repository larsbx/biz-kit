defmodule SpruceGoose.Web.RunReadinessController do
  @moduledoc """
  Governance defines readiness for a workflow run's tasks at once
  (docs/architecture/2026-10-20-run-readiness.md).

      POST …/projects/:project_id/runs/:run_event_id/readiness
           {"governance_key_id", "sop_digest": hex, "sop_version"?: "MAJOR.MINOR.PATCH",
            "inputs": {task_id: {name: hex}}}
           → 201 the definitions to sign, one per task
      POST …/runs/:run_event_id/readiness/:held_id
           {"signatures"} → 201 {events}

  The first request is signed by a governance key of the chapter
  (`Governance.Read`). Predecessors and input names come from the
  blueprint; the request supplies only digests.
  """

  use Phoenix.Controller, formats: [:json]

  import SpruceGoose.Web.Requests

  alias CoopSubstrate.RunReadiness

  def prepare(conn, %{"chapter_id" => ch, "tenant_id" => t, "project_id" => p} = params) do
    with :ok <- governing(conn, ch),
         {:ok, body} <- json_body(conn),
         {:ok, signer} <- string(body["governance_key_id"]),
         {:ok, sop} <- digest(body["sop_digest"]),
         {:ok, version} <- version(body["sop_version"]),
         {:ok, inputs} <- inputs(body["inputs"]),
         {:ok, batch} <-
           RunReadiness.prepare({ch, t, p}, params["run_event_id"], sop, inputs, signer, version) do
      held_batch(conn, batch)
    else
      %Plug.Conn{} = refused -> refused
      error -> refuse(conn, error)
    end
  end

  def define(conn, %{"chapter_id" => ch, "tenant_id" => t, "project_id" => p} = params) do
    with {:ok, body} <- json_body(conn),
         {:ok, signatures} <- bytes(body["signatures"]),
         {:ok, envs} <-
           RunReadiness.define({ch, t, p}, params["run_event_id"], params["held_id"], signatures) do
      appended(conn, envs)
    else
      error -> refuse(conn, error)
    end
  end

  defp digest(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, <<_::256>> = digest} -> {:ok, digest}
      _ -> {:error, :bad_request}
    end
  end

  defp digest(_), do: {:error, :bad_request}

  # Optional; its form is the ledger's to check (`invalid_sop_version`).
  defp version(nil), do: {:ok, nil}
  defp version(version) when is_binary(version), do: {:ok, version}
  defp version(_), do: {:error, :bad_request}

  # {task_id: {name: hex}}, every digest 32 bytes.
  defp inputs(inputs) when is_map(inputs) do
    Enum.reduce_while(inputs, {:ok, %{}}, fn
      {id, names}, {:ok, acc} when is_binary(id) and is_map(names) ->
        case Enum.reduce_while(names, {:ok, %{}}, &input/2) do
          {:ok, digests} -> {:cont, {:ok, Map.put(acc, id, digests)}}
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, {:error, :bad_request}}
    end)
  end

  defp inputs(_), do: {:error, :bad_request}

  defp input({name, hex}, {:ok, acc}) do
    case digest(hex) do
      {:ok, d} -> {:cont, {:ok, Map.put(acc, name, d)}}
      error -> {:halt, error}
    end
  end
end
