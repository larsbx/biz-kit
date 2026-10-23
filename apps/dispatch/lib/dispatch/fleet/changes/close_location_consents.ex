defmodule Dispatch.Fleet.Changes.CloseLocationConsents do
  @moduledoc """
  When a trip completes or is cancelled, its location consents end with it
  plus the grace period (Section 6.1), including those begun while the trip
  had no end recorded, which until now never expired.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, trip ->
      :ok = Dispatch.Operations.Locations.close_consents(trip)
      {:ok, trip}
    end)
  end
end
