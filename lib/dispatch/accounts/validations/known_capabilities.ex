defmodule Dispatch.Accounts.Validations.KnownCapabilities do
  @moduledoc """
  Rejects a manifest containing a key outside `Dispatch.Access.Capabilities`.

  Section 23.2 fixes the capability vocabulary. Without this, a typo would store
  a key that no policy check ever tests — granting nothing while reading as a
  grant — and a novel string could become an ad hoc permission that the shared
  authorization checks know nothing about.
  """

  use Ash.Resource.Validation

  alias Dispatch.Access.Capabilities

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    capabilities = Ash.Changeset.get_attribute(changeset, :capabilities_json) || []

    case Capabilities.unknown(capabilities) do
      [] ->
        :ok

      unknown ->
        # Named directly rather than through `vars`, which is not interpolated
        # into the rendered message: an operator needs to know *which* key.
        {:error,
         field: :capabilities_json,
         message: "contains capabilities that are not canonical: " <> Enum.join(unknown, ", ")}
    end
  end

  @impl Ash.Resource.Validation
  def atomic(changeset, opts, context),
    do: {:not_atomic, inspect(validate(changeset, opts, context))}
end
