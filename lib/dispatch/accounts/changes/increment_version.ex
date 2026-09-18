defmodule Dispatch.Accounts.Changes.IncrementVersion do
  @moduledoc """
  Optimistic concurrency for mutable aggregates (Section 22).

  Section 22 requires named update actions to take `expected_version`, a
  resource change to increment `version`, and a mismatch to return
  `STALE_VERSION`. Two operators editing the same assignment would otherwise
  produce a last-write-wins result with no record that anything was lost.

  `expected_version` is optional here so an internal action can update without
  a read-modify-write cycle; when it is supplied it is enforced.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    current = Ash.Changeset.get_data(changeset, :version) || 0

    case Ash.Changeset.get_argument(changeset, :expected_version) do
      nil ->
        Ash.Changeset.force_change_attribute(changeset, :version, current + 1)

      ^current ->
        Ash.Changeset.force_change_attribute(changeset, :version, current + 1)

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
