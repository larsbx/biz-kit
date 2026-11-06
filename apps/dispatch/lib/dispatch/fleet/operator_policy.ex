defmodule Dispatch.Fleet.OperatorPolicy do
  @moduledoc """
  Binds one assignment to its global User and one trusted profile decision.

  E3 occupancy is enforced by PostgreSQL, without an application count query.
  These reads establish the meaning of the immutable values the constraints
  compare. Planning and activation run inside the writer's transaction. Row
  locks order changes to identity, standing, role, definition and load scope
  before or after admission; clock expiry after admission is not a commit-time
  authorization guarantee.

  The actor still needs tenant-scoped authorization at the Board boundary.
  This module never unions capabilities or returns another tenant's work.
  """

  import Ecto.Query, only: [from: 2]

  alias Dispatch.Access.{Driving, RoleProfile}
  alias Dispatch.Accounts.{RoleAssignment, RoleDefinition}
  alias Dispatch.Repo

  @invalid_role "the selected operator role is not valid for this assignment"
  @inactive_driver "the driver no longer holds a driving role"

  @doc "Derives the private, immutable assignment snapshot under transaction locks."
  def snapshot(changeset) do
    tenant = Ash.Changeset.get_attribute(changeset, :tenant_id)
    load_id = Ash.Changeset.get_attribute(changeset, :load_id)
    participant_id = Ash.Changeset.get_attribute(changeset, :operator_participant_id)
    role_id = Ash.Changeset.get_argument(changeset, :operator_role_assignment_id)
    trip_id = Ash.Changeset.get_attribute(changeset, :id)

    with true <- Repo.in_transaction?(),
         true <- is_nil(changeset.tenant) or changeset.tenant == tenant,
         {:ok, identity} <- identity(tenant, load_id, participant_id),
         {:ok, policy} <- selected_policy(identity, role_id, trip_id, load_id) do
      {:ok, Map.put(policy, :operator_user_id, identity.user_id)}
    else
      _ -> {:error, @invalid_role}
    end
  end

  @doc "Revalidates the stored decision; never changes its User, source or mode."
  def activation(trip) do
    with true <- Repo.in_transaction?(),
         {:ok, identity} <-
           identity(trip.tenant_id, trip.load_id, trip.operator_participant_id),
         true <- identity.user_id == trip.operator_user_id,
         true <- activation_source?(identity, trip) do
      :ok
    else
      _ -> {:error, @inactive_driver}
    end
  end

  @doc "Conservative roster selection when a participant holds multiple driving roles."
  def exclusive?(%{role_definition: %{profile_module: name}}) do
    case RoleProfile.fetch(name) do
      {:ok, profile} -> not profile.allows_concurrent_assignments?()
      _ -> true
    end
  end

  def exclusive?(_role), do: true

  defp identity(tenant, load_id, participant_id) do
    # Lock the load and participant separately before following their keys.
    # A joined stale snapshot must not cause a newly referenced User to escape
    # the standing lock when a writer was already waiting.
    carrier =
      from(l in "loads",
        where: l.id == type(^load_id, :binary_id) and l.tenant_id == type(^tenant, :binary_id),
        select: type(l.carrier_organization_id, :binary_id),
        lock: "FOR SHARE"
      )
      |> Repo.one()

    participant =
      from(p in "participants",
        where:
          p.id == type(^participant_id, :binary_id) and p.tenant_id == type(^tenant, :binary_id),
        select: %{
          user_id: type(p.user_id, :binary_id),
          organization_id: type(p.home_organization_id, :binary_id),
          status: p.status
        },
        lock: "FOR SHARE"
      )
      |> Repo.one()

    with %{status: "ACTIVE", organization_id: ^carrier, user_id: user_id} <- participant,
         true <- not is_nil(carrier),
         "ACTIVE" <- user_status(user_id) do
      {:ok, %{tenant: tenant, carrier: carrier, participant: participant_id, user_id: user_id}}
    else
      _ -> :error
    end
  end

  defp user_status(user_id) do
    from(u in "users",
      where: u.id == type(^user_id, :binary_id),
      select: u.status,
      lock: "FOR SHARE"
    )
    |> Repo.one()
  end

  defp selected_policy(_identity, nil, _trip_id, _load_id) do
    {:ok,
     %{
       operator_exclusive: true,
       operator_role_assignment_id: nil,
       operator_role_definition_id: nil
     }}
  end

  defp selected_policy(identity, role_id, trip_id, load_id) do
    with {:ok, role} <- locked_role(identity.tenant, role_id),
         true <- applicable?(role, identity, trip_id, load_id) do
      {:ok,
       %{
         operator_exclusive: exclusive?(role),
         operator_role_assignment_id: role.id,
         operator_role_definition_id: role.role_definition_id
       }}
    else
      _ -> :error
    end
  end

  defp activation_source?(identity, %{operator_role_assignment_id: nil} = trip) do
    # Historical/default exclusive plans have no source. They may start only
    # with a current exclusive driving grant. Missing concurrent provenance
    # never becomes an implicit permission to activate.
    trip.operator_exclusive and is_nil(trip.operator_role_definition_id) and
      Enum.any?(role_ids(identity), fn id ->
        case selected_policy(identity, id, trip.id, trip.load_id) do
          {:ok, %{operator_exclusive: true}} -> true
          _ -> false
        end
      end)
  end

  defp activation_source?(identity, trip) do
    case selected_policy(identity, trip.operator_role_assignment_id, trip.id, trip.load_id) do
      {:ok, policy} ->
        policy.operator_role_definition_id == trip.operator_role_definition_id and
          policy.operator_exclusive == trip.operator_exclusive

      _ ->
        false
    end
  end

  defp role_ids(identity) do
    from(r in "role_assignments",
      where: r.tenant_id == type(^identity.tenant, :binary_id),
      where: r.principal_id == type(^identity.participant, :binary_id),
      where: r.organization_id == type(^identity.carrier, :binary_id),
      where: r.principal_type == "PARTICIPANT",
      order_by: r.id,
      select: type(r.id, :binary_id)
    )
    |> Repo.all()
  end

  defp locked_role(tenant, role_id) do
    definition_id =
      from(r in "role_assignments",
        where: r.id == type(^role_id, :binary_id) and r.tenant_id == type(^tenant, :binary_id),
        select: type(r.role_definition_id, :binary_id),
        lock: "FOR SHARE"
      )
      |> Repo.one()

    if definition_id do
      from(d in "role_definitions",
        where:
          d.id == type(^definition_id, :binary_id) and d.tenant_id == type(^tenant, :binary_id),
        select: d.id,
        lock: "FOR SHARE"
      )
      |> Repo.all()

      # REVIEWED-UNAUTHORIZED: establishes the operator's own profile decision
      # under locks, after tenant/principal/carrier binding. No grant is exposed.
      Ash.get(RoleAssignment, role_id,
        tenant: tenant,
        authorize?: false,
        load: [:role_definition]
      )
    else
      :error
    end
  end

  defp applicable?(
         %RoleAssignment{role_definition: %RoleDefinition{}} = role,
         identity,
         trip_id,
         load_id
       ) do
    # Take time after all potentially blocking source locks.
    at = DateTime.utc_now()

    role.tenant_id == identity.tenant and role.principal_type == :PARTICIPANT and
      role.principal_id == identity.participant and role.organization_id == identity.carrier and
      role.role_definition.tenant_id == identity.tenant and
      role.role_definition.status == :ACTIVE and Driving.drives?(role, at) and
      scope?(role, trip_id, load_id, at)
  end

  defp applicable?(_role, _identity, _trip_id, _load_id), do: false

  defp scope?(%{scope_type: scope}, _trip_id, _load_id, _at)
       when scope in [:SELF, :ORGANIZATION],
       do: true

  defp scope?(%{scope_type: :ASSIGNMENT, scope_id: id}, trip_id, _load_id, _at),
    do: not is_nil(trip_id) and id == trip_id

  defp scope?(%{scope_type: :LOAD, scope_id: id} = role, _trip_id, load_id, _at)
       when id == load_id do
    # Lock the relationship before evaluating its status and lifetime. Ending
    # it concurrently must either precede admission or wait until it commits.
    from(p in "load_parties",
      where: p.tenant_id == type(^role.tenant_id, :binary_id),
      where: p.load_id == type(^load_id, :binary_id),
      where: p.organization_id == type(^role.organization_id, :binary_id),
      where: p.relationship == "CARRIER",
      order_by: p.id,
      select: p.id,
      lock: "FOR SHARE"
    )
    |> Repo.all()

    at = DateTime.utc_now()

    Dispatch.Access.can?(role, Driving.capability(), at) and
      Dispatch.Access.Party.permits?(role, Driving.capability(), {:LOAD, load_id},
        at: at,
        relationships: :CARRIER
      )
  end

  defp scope?(_role, _trip_id, _load_id, _at), do: false
end
