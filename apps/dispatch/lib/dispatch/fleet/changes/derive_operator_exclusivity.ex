defmodule Dispatch.Fleet.Changes.DeriveOperatorExclusivity do
  @moduledoc """
  Records whether the operator's role profile limits them to one active
  assignment (Section 22.2).

  Section 22.2 applies that limit "for the initial `DRIVER` role profile" and
  lets other profiles declare a different cardinality "through reviewed
  application policy and a matching database constraint". The profile module is
  that policy; this change copies its answer onto the row so the partial unique
  index can be the constraint.

  Derived, never accepted. If a caller could set the flag, opting out of the
  restriction would be a matter of asserting it does not apply — which is not
  what "reviewed application policy" means. An unresolvable or absent role
  assignment leaves the restrictive default in place, so a mistake costs a
  blocked activation with a clear error rather than two active assignments and
  an unattributable location sample.
  """

  use Ash.Resource.Change

  alias Dispatch.Access.RoleProfile
  alias Dispatch.Accounts.RoleAssignment

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :operator_role_assignment_id) do
      nil ->
        changeset

      role_assignment_id ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :operator_exclusive,
          exclusive?(changeset, role_assignment_id)
        )
    end
  end

  defp exclusive?(changeset, role_assignment_id) do
    with {:ok, assignment} <- fetch_assignment(changeset, role_assignment_id),
         %{profile_module: module_name} <- assignment.role_definition,
         {:ok, module} <- RoleProfile.fetch(module_name) do
      not module.allows_concurrent_assignments?()
    else
      # Unresolvable profile: keep the restriction rather than lift it.
      _ -> true
    end
  end

  defp fetch_assignment(changeset, role_assignment_id) do
    tenant = changeset.tenant || Ash.Changeset.get_attribute(changeset, :tenant_id)

    # REVIEWED-UNAUTHORIZED: reads the operator's own role assignment purely to
    # decide a cardinality constraint. Subjecting it to the actor's read policy
    # would make a dispatcher unable to plan work for an operator whose role
    # assignment they cannot read, and the failure would silently relax the
    # restriction rather than deny. No field of the row reaches the caller; only
    # the boolean is stored.
    RoleAssignment
    |> Ash.get(role_assignment_id, tenant: tenant, authorize?: false, load: [:role_definition])
    |> case do
      {:ok, assignment} -> {:ok, assignment}
      _ -> :error
    end
  end
end
