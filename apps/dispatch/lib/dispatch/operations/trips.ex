defmodule Dispatch.Operations.Trips do
  @moduledoc """
  A participant's own trips: their assignments not yet over, each with the
  location consent covering it now, if any (`GET /v1/me/assignments`).

  The field app needs both to share location (Section 25.3): which assignment
  to consent for, and, after a reboot, the server's confirmation that "the
  persisted consent is valid and the active assignment still exists".

  `assignment.read.self` is constrained `active_assignment_only` for DRIVER
  (Section 23.2). Read here as *not yet over*: PLANNED or ACTIVE and not past
  its end, the same assignments `Locations.begin_consent/2` accepts. Completed,
  cancelled and ended trips are history, which this capability does not reach.
  """

  require Ash.Query

  alias Dispatch.Access.Actor
  alias Dispatch.Fleet.Assignment
  alias Dispatch.Operations.Locations

  @type trip :: %{assignment: struct(), consent: struct() | nil}

  @doc "The actor's own trips not yet over, soonest first."
  @spec mine(Actor.t()) :: {:ok, [trip()]} | {:error, :forbidden}
  def mine(%Actor{} = actor) do
    if Actor.can?(actor, "assignment.read.self") do
      covering = Locations.covering(actor)
      now = DateTime.utc_now()

      trips =
        Assignment
        |> Ash.Query.filter(
          operator_participant_id == ^actor.principal_id and status in [:PLANNED, :ACTIVE] and
            (is_nil(ends_at) or ends_at > ^now)
        )
        |> Ash.Query.sort(starts_at: :asc, id: :asc)
        # REVIEWED-UNAUTHORIZED: Assignment has no policies yet; the filter on
        # the actor's own participant ID is the authorization, checked above.
        |> Ash.read!(authorize?: false, tenant: actor.tenant_id)
        |> Enum.map(&%{assignment: &1, consent: Map.get(covering, &1.id)})

      {:ok, trips}
    else
      {:error, :forbidden}
    end
  end
end
