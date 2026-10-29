defmodule Dispatch.Fleet.PartnerActions do
  @moduledoc "Partner contributions through authorized Ash actions; no approval or execution path."
  require Ash.Query
  alias Dispatch.Access.Checks.PartnerScope
  alias Dispatch.Fleet.{Stop, DocumentReference}
  alias Dispatch.Operations.StopReadinessEvent
  alias Dispatch.Communications.ActionProposal

  def submit(actor, stop_id, kind, params) do
    with {:ok, actor} <- PartnerScope.fresh(actor),
         {:ok, %Stop{}} <- stop(actor, stop_id),
         {:ok, resource, allowed} <- resource(kind),
         true <- Enum.all?(Map.keys(params), &(&1 in allowed)) do
      input =
        params
        |> Map.put("stop_id", stop_id)
        |> Map.put_new("correlation_id", Ash.UUID.generate())
        |> Map.reject(fn {key, value} -> value == "" and key in ["expected_latest_id"] end)

      resource
      |> Ash.Changeset.for_create(:submit, input, actor: actor, tenant: actor.tenant_id)
      |> Ash.create()
    else
      false -> {:error, :invalid_input}
      _ -> {:error, :not_found}
    end
  end

  def stop(actor, id) do
    Stop
    |> Ash.Query.for_read(:partner)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor, tenant: actor.tenant_id)
  end

  defp resource(:readiness),
    do:
      {:ok, StopReadinessEvent,
       ~w(state note occurred_at correlation_id expected_version expected_latest_id)}

  defp resource(:document),
    do: {:ok, DocumentReference, ~w(category label reference correlation_id expected_version)}

  defp resource(:proposal),
    do:
      {:ok, ActionProposal,
       ~w(kind window_start window_end instructions expires_at correlation_id expected_version)}

  defp resource(_), do: :error
end
