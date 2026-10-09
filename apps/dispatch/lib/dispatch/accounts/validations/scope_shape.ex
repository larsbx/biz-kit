defmodule Dispatch.Accounts.Validations.ScopeShape do
  @moduledoc """
  Keeps `scope_type` and `scope_id` consistent.

  `SELF` and `ORGANIZATION` are already bounded by `organization_id`, so a
  `scope_id` there would be a second, unchecked bound that no policy reads.
  `LOAD`, `STOP`, and `ASSIGNMENT` are meaningless without one: a
  `LOAD`-scoped grant with a null scope would read as "some load" and Section
  22.2 requires it to name one.
  """

  use Ash.Resource.Validation

  @unscoped [:SELF, :ORGANIZATION]

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    scope_type = Ash.Changeset.get_attribute(changeset, :scope_type)
    scope_id = Ash.Changeset.get_attribute(changeset, :scope_id)

    cond do
      scope_type in @unscoped and not is_nil(scope_id) ->
        {:error,
         field: :scope_id,
         message: "must be empty for a #{scope_type} scope, which the organization already bounds"}

      scope_type not in @unscoped and is_nil(scope_id) ->
        {:error, field: :scope_id, message: "is required for a #{scope_type} scope"}

      true ->
        :ok
    end
  end

  @impl Ash.Resource.Validation
  def atomic(changeset, opts, context),
    do: {:not_atomic, inspect(validate(changeset, opts, context))}
end
