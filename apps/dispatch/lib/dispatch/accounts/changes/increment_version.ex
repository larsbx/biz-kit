defmodule Dispatch.Accounts.Changes.IncrementVersion do
  @moduledoc """
  Validates the caller's expected aggregate version (Section 22).

  The action's `optimistic_lock(:version)` change performs the load-bearing
  database compare-and-increment. This change preserves the API contract:
  when a caller supplies `expected_version`, a mismatch against the version
  they loaded is reported as `STALE_VERSION` before the update is attempted.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    current = Ash.Changeset.get_data(changeset, :version) || 0

    case Ash.Changeset.get_argument(changeset, :expected_version) do
      nil ->
        changeset

      ^current ->
        changeset

      _mismatch ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidChanges.exception(
            fields: [:version],
            message: "STALE_VERSION: the record changed since it was read"
          )
        )
    end
  end
end
