defmodule DispatchWeb.ViewModels.PartnerLoadView do
  @moduledoc "Contracted-load projection with no rates, route, timeline or carrier notes."
  require Ash.Query
  alias Dispatch.Access.{Actor}
  alias Dispatch.Access.Checks.PartnerScope
  alias Dispatch.Fleet.{Load, Stop}
  alias Dispatch.Communications.Conversation
  alias DispatchWeb.ViewModels.{FactSummary, PartnerStopView}

  defstruct [
    :load_id,
    :external_reference,
    :status_summary,
    stops: [],
    location_summary: nil,
    communications: []
  ]

  def list(actor) do
    with {:ok, actor} <- PartnerScope.fresh(actor),
         true <- Actor.can?(actor, "load.read"),
         true <- actor.role_assignment.scope_type == :LOAD,
         {:ok, loads} <-
           Load
           |> Ash.Query.for_read(:partner)
           |> Ash.read(actor: actor, tenant: actor.tenant_id) do
      {:ok, Enum.map(loads, &from(actor, &1))}
    else
      _ -> {:error, :not_found}
    end
  end

  def build(actor, id) do
    with {:ok, views} <- list(actor),
         %__MODULE__{} = view <- Enum.find(views, &(&1.load_id == id)) do
      {:ok, view}
    else
      _ -> {:error, :not_found}
    end
  end

  defp from(actor, load) do
    stops =
      Stop
      |> Ash.Query.for_read(:partner)
      |> Ash.Query.filter(load_id == ^load.id)
      |> Ash.Query.sort(:sequence)
      |> Ash.read!(actor: actor, tenant: actor.tenant_id)

    %__MODULE__{
      load_id: load.id,
      external_reference: load.external_reference,
      status_summary: FactSummary.new(load.status, :OBSERVED, load.updated_at),
      communications: threads(actor, load.id),
      stops:
        Enum.map(stops, fn stop ->
          %{
            stop_id: stop.id,
            kind: stop.kind,
            address_text: stop.address_text,
            version: stop.version,
            window_start: stop.window_start,
            window_end: stop.window_end,
            proposals: PartnerStopView.proposals(actor, stop),
            can_propose: Actor.can?(actor, "proposal.create")
          }
        end)
    }
  end

  defp threads(actor, load_id) do
    Conversation
    |> Ash.Query.filter(load_id == ^load_id)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(100)
    |> Ash.read!(actor: actor, tenant: actor.tenant_id)
    |> Enum.map(fn thread ->
      %{
        id: thread.id,
        subject: thread.subject,
        channel: thread.channel,
        state: thread.state,
        source: thread.source,
        occurred_at: thread.updated_at
      }
    end)
  end
end
