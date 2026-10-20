defmodule Dispatch.Accounts.Validations.KnownConstraints do
  @moduledoc """
  Rejects a constraint map that is not `capability => [constraint]` over the
  canonical vocabularies of `Dispatch.Access.Capabilities`.

  Section 23.2 names the constraints (`self_only`, `requires_consent`, …) and
  attaches them to capabilities. A constraint on a capability the definition
  does not grant constrains nothing, and a value that is not a list of known
  names is either a typo or a structure no check reads. Both are refused at
  write time, so everything downstream — policies, and the signed capability
  document, whose canonical encoding admits only plain strings and lists —
  sees the one shape it expects.
  """

  use Ash.Resource.Validation

  alias Dispatch.Access.Capabilities

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    constraints = Ash.Changeset.get_attribute(changeset, :constraints_json) || %{}
    granted = Ash.Changeset.get_attribute(changeset, :capabilities_json) || []
    known = Enum.map(Capabilities.constraints(), &Atom.to_string/1)

    case Enum.reject(constraints, &valid?(&1, granted, known)) do
      [] ->
        :ok

      invalid ->
        {:error,
         field: :constraints_json,
         message:
           "must map granted capabilities to lists of " <>
             Enum.join(known, ", ") <>
             "; invalid entries: " <> Enum.map_join(invalid, ", ", &to_string(elem(&1, 0)))}
    end
  end

  defp valid?({capability, names}, granted, known) when is_list(names),
    do: capability in granted and Enum.all?(names, &(&1 in known))

  defp valid?(_entry, _granted, _known), do: false

  @impl Ash.Resource.Validation
  def atomic(changeset, opts, context),
    do: {:not_atomic, inspect(validate(changeset, opts, context))}
end
