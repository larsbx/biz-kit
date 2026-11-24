defmodule Dispatch.Fleet.Changes.GuardAssignmentTransition do
  @moduledoc """
  Applies lifecycle and operator admission checks to direct Ash updates too.

  Board supplies actor authorization and audit. This resource guard closes the
  terminal-reactivation path without claiming that direct Ash is an authorized
  operational API. PostgreSQL remains the occupancy authority for all writers.
  """

  use Ash.Resource.Change

  import Ecto.Query, only: [from: 2]

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &guard/1)
  end

  defp guard(changeset) do
    if Dispatch.Repo.in_transaction?() do
      trip = changeset.data

      from(a in "assignments",
        where:
          a.id == type(^trip.id, :binary_id) and a.tenant_id == type(^trip.tenant_id, :binary_id),
        select: a.id,
        lock: "FOR UPDATE"
      )
      |> Dispatch.Repo.all()

      # REVIEWED-UNAUTHORIZED: resource lifecycle validation under its row lock;
      # Board separately authorizes the actor and confines the load's carrier.
      with {:ok, fresh} <-
             Ash.get(changeset.resource, trip.id, tenant: trip.tenant_id, authorize?: false),
           true <- fresh.version == trip.version,
           :ok <- permitted(fresh.status, changeset.action.name),
           :ok <- operator(fresh, changeset.action.name) do
        changeset
      else
        false -> error(changeset, "STALE_VERSION: the record changed since it was read")
        {:error, message} when is_binary(message) -> error(changeset, message)
        _ -> error(changeset, "the assignment is unavailable")
      end
    else
      error(changeset, "assignment transitions require a transaction")
    end
  end

  defp permitted(:PLANNED, action) when action in [:activate, :cancel], do: :ok
  defp permitted(:ACTIVE, action) when action in [:complete, :cancel], do: :ok
  defp permitted(status, action), do: {:error, "cannot #{action} a #{status} trip"}

  defp operator(trip, :activate), do: Dispatch.Fleet.OperatorPolicy.activation(trip)
  defp operator(_trip, _action), do: :ok

  defp error(changeset, message),
    do: Ash.Changeset.add_error(changeset, field: :status, message: message)
end
