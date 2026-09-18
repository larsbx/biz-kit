defmodule DispatchWeb.ViewModels.OperationsView do
  @moduledoc """
  The field-authorized carrier roster for the operations overview.

  The query is bounded by the selected assignment's organization before rows
  are returned. Revalidation happens before the query so a long-lived stream
  cannot reuse the authority value captured when its HTTP request began.
  """

  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.Participant
  alias Dispatch.Identity.PrincipalResolution
  alias DispatchWeb.ViewModels.FactSummary

  require Ash.Query

  @enforce_keys [:organization_id, :participants]
  defstruct [:organization_id, :participants]

  @type participant :: %{
          participant_id: Ash.UUID.t(),
          public_name: String.t(),
          status: atom(),
          current_status: FactSummary.t() | nil
        }
  @type t :: %__MODULE__{organization_id: Ash.UUID.t(), participants: [participant()]}

  @spec build(Actor.t()) :: {:ok, t()} | {:error, :not_found}
  def build(%Actor{} = actor) do
    with {:ok, actor} <- PrincipalResolution.revalidate(actor),
         true <- Actor.can?(actor, "operations.participant.read"),
         {:ok, participants} <- fetch(actor) do
      {:ok,
       %__MODULE__{
         organization_id: actor.role_assignment.organization_id,
         participants: Enum.map(participants, &row(&1, actor))
       }}
    else
      _nothing_to_report -> {:error, :not_found}
    end
  end

  def build(_actor), do: {:error, :not_found}

  defp fetch(actor) do
    Participant
    |> Ash.Query.filter(
      home_organization_id == ^actor.role_assignment.organization_id and status == :ACTIVE
    )
    |> Ash.Query.sort(public_name: :asc, id: :asc)
    |> Ash.read(actor: actor, tenant: actor.tenant_id)
    |> case do
      {:ok, participants} -> {:ok, participants}
      _refused -> :error
    end
  end

  defp row(participant, actor) do
    %{
      participant_id: participant.id,
      public_name: participant.public_name,
      status: participant.status,
      current_status: current_status(participant, actor)
    }
  end

  defp current_status(participant, actor) do
    Dispatch.Operations.ParticipantStatusEvent.current(participant.id,
      actor: actor,
      tenant: actor.tenant_id
    )
    |> case do
      {:ok, %{} = event} ->
        FactSummary.new(event.status, :PARTICIPANT, event.occurred_at,
          received_at: event.recorded_at
        )

      _none ->
        nil
    end
  end
end
