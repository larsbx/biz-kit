defmodule Dispatch.Fleet.Changes.DeriveOperatorExclusivity do
  @moduledoc """
  Stores a locked, server-derived User and role-policy snapshot for E3.

  An omitted source remains exclusive. An explicitly supplied source must be
  valid for this operator and trip; lookup failure is an error. The database
  makes the resulting identity, provenance and mode immutable after planning.
  """

  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Dispatch.Fleet.OperatorPolicy.snapshot(changeset) do
        {:ok, snapshot} ->
          Enum.reduce(snapshot, changeset, fn {field, value}, changeset ->
            Ash.Changeset.force_change_attribute(changeset, field, value)
          end)

        {:error, message} ->
          Ash.Changeset.add_error(changeset,
            field: :operator_role_assignment_id,
            message: message
          )
      end
    end)
  end
end
