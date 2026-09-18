defmodule Dispatch.Accounts.Validations.SelfServicePrincipal do
  @moduledoc """
  Keeps self-service capabilities away from service principals.

  Section 23.2: "Operational self-service capabilities require
  `principal_type=PARTICIPANT`." A `SERVICE` principal holding
  `status.declare.self` or `proposal.decide.self` would let an agent runtime or
  a background job declare a status or approve a commitment on a person's
  behalf — which Section 9 and Section 8.3 both forbid, and which the approval
  flow exists specifically to prevent.

  The capability set is read from the definition rather than from the role key,
  so a custom profile cannot slip past this by not being one of the seeded six.
  """

  use Ash.Resource.Validation

  alias Dispatch.Access.Capabilities
  alias Dispatch.Accounts.RoleDefinition

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, context) do
    case Ash.Changeset.get_attribute(changeset, :principal_type) do
      :SERVICE -> validate_service_principal(changeset, context)
      _participant_or_unset -> :ok
    end
  end

  # Branches are explicit rather than a `with`/`else` chain because every
  # failure mode here has to deny. An earlier version collapsed them into
  # `else -> :ok`, which meant an unreadable or missing definition allowed the
  # grant: exactly the fail-open this validation exists to prevent.
  defp validate_service_principal(changeset, context) do
    case Ash.Changeset.get_attribute(changeset, :role_definition_id) do
      nil ->
        # A missing reference is another validation's error to report, and the
        # create action cannot succeed without it.
        :ok

      definition_id ->
        case fetch_definition(changeset, definition_id, context) do
          {:ok, definition} -> reject_self_service(definition)
          :error -> deny_unreadable(definition_id)
        end
    end
  end

  defp reject_self_service(definition) do
    case self_service_capabilities(definition) do
      [] ->
        :ok

      offending ->
        {:error,
         field: :principal_type,
         message:
           "a SERVICE principal may not hold self-service capabilities: " <>
             Enum.join(offending, ", ")}
    end
  end

  defp deny_unreadable(definition_id) do
    {:error,
     field: :role_definition_id,
     message:
       "could not be read, so its capabilities cannot be checked against a " <>
         "SERVICE principal: " <> inspect(definition_id)}
  end

  @impl Ash.Resource.Validation
  def atomic(changeset, opts, context),
    do: {:not_atomic, inspect(validate(changeset, opts, context))}

  defp fetch_definition(changeset, definition_id, context) do
    RoleDefinition
    |> Ash.get(definition_id,
      tenant: changeset.tenant || Ash.Changeset.get_attribute(changeset, :tenant_id),
      # REVIEWED-UNAUTHORIZED: Section 21.1 permits narrowly reviewed internal
      # code. This read enforces a security rule and must not be subject to the
      # actor's own read policy: an actor who could not read the definition
      # would otherwise make the check unevaluable, and an unevaluable security
      # check that denies (as it now does) would block legitimate grants, while
      # one that allows would be the fail-open this validation exists to
      # prevent. Reading with the service's own authority keeps the rule
      # decidable. The row is not returned to the caller; only the decision is.
      authorize?: false,
      actor: context.actor
    )
    |> case do
      {:ok, definition} -> {:ok, definition}
      _ -> :error
    end
  end

  defp self_service_capabilities(definition) do
    definition
    |> Dispatch.Access.definition_capabilities()
    |> Enum.filter(&Capabilities.self_service?/1)
    |> Enum.sort()
  end
end
