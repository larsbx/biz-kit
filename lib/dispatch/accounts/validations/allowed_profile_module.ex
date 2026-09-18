defmodule Dispatch.Accounts.Validations.AllowedProfileModule do
  @moduledoc """
  Rejects a `profile_module` that is not compiled in and allowlisted.

  Section 23.2: "`role_definitions.profile_module` may reference only modules
  compiled into the release and listed in configuration. Database content cannot
  name or load arbitrary code."

  This is the write-time half. Section 31 fails startup when a seeded or active
  definition already references something else, which covers a row written
  before an allowlist was narrowed.
  """

  use Ash.Resource.Validation

  alias Dispatch.Access.RoleProfile

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    module = Ash.Changeset.get_attribute(changeset, :profile_module)

    case RoleProfile.fetch(module) do
      {:ok, _module} ->
        :ok

      {:error, :profile_module_not_allowed} ->
        {:error,
         field: :profile_module,
         message:
           "must be a compiled module listed in ROLE_PROFILE_MODULE_ALLOWLIST; got " <>
             inspect(module)}
    end
  end

  @impl Ash.Resource.Validation
  def atomic(changeset, opts, context),
    do: {:not_atomic, inspect(validate(changeset, opts, context))}
end
