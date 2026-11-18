defmodule Dispatch.Access.Checks.PartnerMutation do
  @moduledoc "Ash admission for readiness, proof references and nonbinding proposals."
  use Ash.Policy.SimpleCheck
  require Ash.Query
  alias Dispatch.Access.{Actor, Party}
  alias Dispatch.Access.Checks.PartnerScope
  alias Dispatch.Fleet.Stop

  @impl true
  def describe(_), do: "selected partner can contribute to this stop"

  @impl true
  def match?(actor, %{changeset: changeset}, opts) do
    kind = Keyword.fetch!(opts, :kind)
    stop_id = Ash.Changeset.get_attribute(changeset, :stop_id)

    with {:ok, actor} <- PartnerScope.fresh(actor),
         true <- changeset.tenant == actor.tenant_id,
         true <- capability?(actor, changeset, kind),
         {:ok, %Stop{} = stop} <-
           Stop
           |> Ash.Query.for_read(:partner)
           |> Ash.Query.filter(id == ^stop_id)
           |> Ash.read_one(actor: actor, tenant: actor.tenant_id) do
      (actor.role_assignment.scope_type == :LOAD and kind == :proposal) or
        (actor.role_assignment.scope_type == :STOP and PartnerScope.stop_kind?(actor, stop) and
           Party.permits?(actor.role_assignment, "stop.read", {:STOP, stop.id},
             at: actor.at,
             relationships: relationship(stop.kind)
           ))
    else
      _ -> false
    end
  end

  def match?(_, _, _), do: false

  defp relationship(:PICKUP), do: [:SHIPPER, :FACILITY]
  defp relationship(:DELIVERY), do: [:RECEIVER, :FACILITY]
  defp relationship(_), do: []

  defp capability?(actor, _, :readiness), do: Actor.can?(actor, "stop.update.readiness")
  defp capability?(actor, _, :document), do: Actor.can?(actor, "document_reference.add")

  defp capability?(actor, changeset, :proposal) do
    capability =
      case Ash.Changeset.get_attribute(changeset, :kind) do
        :APPOINTMENT -> "appointment.propose"
        :INSTRUCTION -> "instruction.propose"
        _ -> ""
      end

    Actor.can?(actor, "proposal.create") and Actor.can?(actor, capability)
  end
end
