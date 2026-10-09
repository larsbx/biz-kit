defmodule DispatchWeb.ViewModels.OperationsParticipantView do
  @moduledoc """
  What an operations page may show about one participant (Sections 4.3, 23.2).

  Two prohibitions apply, and they are different in kind.

  **Rows.** Acceptance criterion 15: a dispatcher sees only carrier-related
  participants, and ending the relationship terminates access. So the actor's
  own organization bounds the lookup, and the assignment is re-read from the
  database on every build.

  That last part is not decoration. An `Actor` holds its assignment as a value,
  so `Dispatch.Access.can?/3` would happily answer from a grant revoked an hour
  ago. A request resolves its actor afresh and hides this; a stream does not,
  and Section 33.2 requires a stream to die immediately.

  **Fields.** Acceptance criterion 14 keeps precise location, message content
  and negotiated load data away from an administrator, and Section 23.2 keeps
  precise location away from a *dispatcher* too: it is a separate capability
  that additionally requires active consent. A page that showed coordinates
  because the viewer could open the page would be wrong for the role the page
  was designed for — which is why this struct has no field for them.

  What it carries about location is freshness, not position: that a location
  exists and how old it is. Section 26.6 draws staleness from age, and age is
  not a coordinate.

  Slice 2 owns location samples. When it lands, widening this struct is the
  deliberate act it should be, rather than filling a field that was already
  waiting.
  """

  alias Dispatch.Access.Actor
  alias Dispatch.Identity.PrincipalResolution
  alias Dispatch.Accounts.Participant
  alias DispatchWeb.ViewModels.FactSummary

  require Ash.Query

  @enforce_keys [:participant_id, :public_name, :status]
  defstruct [
    :participant_id,
    :public_name,
    :status,
    :current_status,
    :location_freshness
  ]

  @type t :: %__MODULE__{
          participant_id: Ash.UUID.t(),
          public_name: String.t(),
          status: atom(),
          current_status: FactSummary.t() | nil,
          location_freshness: FactSummary.t() | nil
        }

  @doc """
  Builds the view for `participant_id`, or reports nothing.

  Every refusal is `{:error, :not_found}`: a participant in another carrier, one
  that does not exist, and a viewer whose assignment has been revoked are
  indistinguishable to the caller. Acceptance criterion 19 requires that of an
  unrelated subject, and the same reasoning covers the others — "forbidden"
  confirms the row is there.
  """
  @spec build(Actor.t(), Ash.UUID.t()) :: {:ok, t()} | {:error, :not_found}
  def build(%Actor{} = actor, participant_id) when is_binary(participant_id) do
    with {:ok, actor} <- PrincipalResolution.revalidate(actor),
         true <- Actor.can?(actor, "operations.participant.read"),
         {:ok, participant} <- fetch(actor, participant_id) do
      {:ok, from(participant, actor)}
    else
      _nothing_to_report -> {:error, :not_found}
    end
  end

  def build(_actor, _participant_id), do: {:error, :not_found}

  # `Actor.can?/2` re-derives capabilities from the assignment's validity
  # interval at the actor's own instant, so a revoked assignment stops
  # satisfying the guard above without anything else having to notice.
  #
  # The carrier bound is in the query rather than in a check afterwards: a
  # participant outside it is not found, by the same read that finds one inside.
  defp fetch(actor, participant_id) do
    Participant
    |> Ash.Query.filter(
      id == ^participant_id and
        home_organization_id == ^actor.role_assignment.organization_id
    )
    |> Ash.read_one(actor: actor, tenant: actor.tenant_id)
    |> case do
      {:ok, %Participant{} = participant} -> {:ok, participant}
      _absent_or_refused -> :error
    end
  end

  defp from(%Participant{} = participant, actor) do
    %__MODULE__{
      participant_id: participant.id,
      public_name: participant.public_name,
      status: participant.status,
      current_status: current_status(participant, actor),
      location_freshness: nil
    }
  end

  # The latest declaration, carrying its source. Section 1 keeps a declaration
  # distinct from an observation, so the page says which it is rather than
  # rendering a bare value that reads like an established fact.
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
