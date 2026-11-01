defmodule Dispatch.Accounts.Administration do
  @moduledoc """
  Role-assignment management by an administrator (Sections 4.3, 23.3).

  Section 23.3's rules, each enforced here rather than left to the page:

  - The actor's assignment carries `role_assignment.manage`. Anything else is
    `:not_found`, as for every page an assignment does not open.
  - The actor signed in within the last five minutes: a step-up. A session
    that lasts until sign-out says nothing of how recently it was earned, so
    the time of sign-in is asked, not the session's age.
  - An administrator cannot create, expand or reactivate their own
    assignment: a grant to oneself is refused whatever the role.
  - The organization's last assignment carrying `role_assignment.manage` held
    by someone who can still sign in (an active participant of an active
    user, as `Dispatch.Identity.PrincipalResolution` requires) cannot be
    revoked. Roles are granted to active participants only.
  - A grant names a whole role definition; nothing can be assigned that the
    definition does not carry. Only `SELF` and `ORGANIZATION` profiles are
    granted here: a `LOAD` or `STOP` grant also needs its party row, which
    belongs with the load or stop.

  The idempotency key is the caller's (`Dispatch.Idempotency`). Changes to one
  organization's assignments are serialized, so two administrators revoking
  each other at once cannot both succeed and leave none.

  Administration confers no operational sight: an `ADMIN` assignment still
  opens no operations page (Section 23.3), until a second, operational
  assignment is granted, by someone else.
  """

  require Ash.Query

  import Ecto.Query, only: [from: 2]

  alias Dispatch.Access
  alias Dispatch.Identity.PrincipalResolution
  alias Dispatch.Access.{Actor, RoleProfile}
  alias Dispatch.Accounts.{Participant, RoleAssignment, RoleDefinition}
  alias Dispatch.Audit.AuditEvent

  @manage "role_assignment.manage"
  @step_up_seconds 300
  @grantable_scopes [:SELF, :ORGANIZATION]

  @type refusal ::
          :not_found
          | :step_up_required
          | :own_assignment
          | :last_administrator
          | :already_granted
          | :stale

  @typedoc "One participant of the organization and the assignments they hold."
  @type member :: %{participant: Participant.t(), assignments: [RoleAssignment.t()]}

  @doc "How long a sign-in counts as recent for a role change."
  @spec step_up_seconds() :: pos_integer()
  def step_up_seconds, do: @step_up_seconds

  @doc """
  The organization's participants with their active assignments, and the
  definitions that may be granted.
  """
  @spec overview(Actor.t()) ::
          {:ok, %{members: [member()], grantable: [RoleDefinition.t()]}} | {:error, :not_found}
  def overview(%Actor{} = actor) do
    with :ok <- manages(actor) do
      held = Enum.group_by(active(actor), & &1.principal_id)

      members =
        actor
        |> participants()
        |> Enum.map(&%{participant: &1, assignments: Map.get(held, &1.id, [])})

      {:ok, %{members: members, grantable: grantable(actor)}}
    end
  end

  @doc "Grants `role_definition_id` to `participant_id` in the actor's organization."
  @spec grant(Actor.t(), map(), DateTime.t() | nil) ::
          {:ok, RoleAssignment.t()} | {:error, refusal()}
  def grant(%Actor{} = actor, params, authenticated_at) do
    serialized(actor, fn current ->
      with :ok <- manages(current),
           :ok <- recent(authenticated_at, current.at),
           {:ok, participant} <- participant(current, params["participant_id"]),
           :ok <- not_own(current, participant.id),
           {:ok, definition, scope} <- definition(current, params["role_definition_id"]),
           :ok <- not_held(current, participant, definition) do
        assignment = create!(current, participant, definition, scope)
        audit!(current, "role_assignment.granted", assignment, definition)
        {:ok, assignment}
      end
    end)
  end

  @doc """
  Revokes `assignment_id`, if it is still at `expected_version`. The version
  is required: without it a stale page could revoke whatever is current.
  """
  @spec revoke(Actor.t(), String.t(), integer() | nil, DateTime.t() | nil) ::
          {:ok, RoleAssignment.t()} | {:error, refusal()}
  def revoke(%Actor{} = actor, assignment_id, expected_version, authenticated_at) do
    serialized(actor, fn current_actor ->
      with :ok <- manages(current_actor),
           :ok <- recent(authenticated_at, current_actor.at),
           {:ok, assignment} <- held(current_actor, assignment_id),
           :ok <- current(assignment, expected_version),
           :ok <- not_last_administrator(current_actor, assignment) do
        revoked =
          assignment
          |> Ash.Changeset.for_update(:revoke, %{})
          # REVIEWED-UNAUTHORIZED: authorized above against Section 23.3's rules.
          |> Ash.update!(authorize?: false, tenant: current_actor.tenant_id)

        audit!(current_actor, "role_assignment.revoked", revoked, assignment.role_definition)
        {:ok, revoked}
      end
    end)
  end

  defp manages(actor), do: if(Actor.can?(actor, @manage), do: :ok, else: {:error, :not_found})

  defp recent(%DateTime{} = authenticated_at, now) do
    if DateTime.diff(now, authenticated_at) <= @step_up_seconds,
      do: :ok,
      else: {:error, :step_up_required}
  end

  defp recent(_never_said, _now), do: {:error, :step_up_required}

  defp not_own(actor, participant_id),
    do: if(participant_id == actor.principal_id, do: {:error, :own_assignment}, else: :ok)

  # Checked rather than left to the unique index: grants are serialized, so the
  # answer holds until the insert, and the index stays the backstop.
  defp not_held(actor, participant, definition) do
    if Enum.any?(
         active(actor),
         &(&1.principal_id == participant.id and &1.role_definition_id == definition.id)
       ),
       do: {:error, :already_granted},
       else: :ok
  end

  defp current(%RoleAssignment{version: version}, version), do: :ok

  defp current(_assignment, _expected), do: {:error, :stale}

  defp not_last_administrator(actor, assignment) do
    administers? = &Access.can?(&1, @manage, actor.at)
    can_sign_in = signs_in(actor)

    others =
      Enum.filter(active(actor), fn other ->
        other.id != assignment.id and administers?.(other) and
          MapSet.member?(can_sign_in, other.principal_id)
      end)

    if administers?.(assignment) and others == [],
      do: {:error, :last_administrator},
      else: :ok
  end

  defp participants(actor) do
    Participant
    |> Ash.Query.filter(home_organization_id == ^organization(actor))
    |> Ash.Query.sort(:public_name)
    # REVIEWED-UNAUTHORIZED: the organization's roster, for its administrator.
    |> Ash.read!(authorize?: false, tenant: actor.tenant_id)
  end

  defp participant(actor, id) when is_binary(id) do
    case Ash.get(Participant, id, authorize?: false, tenant: actor.tenant_id) do
      {:ok, %Participant{home_organization_id: org, status: :ACTIVE} = participant} ->
        if org == organization(actor), do: {:ok, participant}, else: {:error, :not_found}

      _unknown ->
        {:error, :not_found}
    end
  end

  defp participant(_actor, _id), do: {:error, :not_found}

  # Participants of the tenant who can sign in: active, of an active user. The
  # same conditions `PrincipalResolution` puts on every request.
  defp signs_in(actor) do
    from(p in "participants",
      join: u in "users",
      on: u.id == p.user_id,
      where: p.tenant_id == type(^actor.tenant_id, :binary_id),
      where: p.status == "ACTIVE" and u.status == "ACTIVE",
      select: type(p.id, :binary_id)
    )
    # REVIEWED-UNAUTHORIZED: who can still sign in, to keep one administrator.
    |> Dispatch.Repo.all()
    |> MapSet.new()
  end

  defp active(actor) do
    RoleAssignment
    |> Ash.Query.for_read(:active, %{at: actor.at})
    |> Ash.Query.filter(
      organization_id == ^organization(actor) and principal_type == :PARTICIPANT
    )
    |> Ash.Query.load(:role_definition)
    # REVIEWED-UNAUTHORIZED: the organization's assignments, for its administrator.
    |> Ash.read!(authorize?: false, tenant: actor.tenant_id)
  end

  defp held(actor, id) do
    case Enum.find(active(actor), &(&1.id == id)) do
      nil -> {:error, :not_found}
      assignment -> {:ok, assignment}
    end
  end

  defp grantable(actor) do
    RoleDefinition
    |> Ash.Query.filter(status == :ACTIVE)
    |> Ash.Query.sort(:label)
    # REVIEWED-UNAUTHORIZED: the tenant's role catalogue, for its administrator.
    |> Ash.read!(authorize?: false, tenant: actor.tenant_id)
    |> Enum.filter(&(scope(&1) in @grantable_scopes))
  end

  defp definition(actor, id) do
    case Enum.find(grantable(actor), &(&1.id == id)) do
      nil -> {:error, :not_found}
      definition -> {:ok, definition, scope(definition)}
    end
  end

  defp scope(definition) do
    case RoleProfile.fetch(definition.profile_module) do
      {:ok, module} -> module.scope_type()
      {:error, :profile_module_not_allowed} -> nil
    end
  end

  defp create!(actor, participant, definition, scope) do
    RoleAssignment
    |> Ash.Changeset.for_create(:grant, %{
      tenant_id: actor.tenant_id,
      principal_type: :PARTICIPANT,
      principal_id: participant.id,
      organization_id: organization(actor),
      role_definition_id: definition.id,
      scope_type: scope,
      starts_at: actor.at
    })
    # REVIEWED-UNAUTHORIZED: authorized above against Section 23.3's rules.
    |> Ash.create!(authorize?: false, tenant: actor.tenant_id)
  end

  defp audit!(actor, event_type, assignment, definition) do
    AuditEvent
    |> Ash.Changeset.for_create(:record, %{
      tenant_id: actor.tenant_id,
      event_type: event_type,
      actor_type: actor.principal_type,
      actor_id: actor.principal_id,
      role_assignment_id: actor.role_assignment.id,
      subject_type: "participant",
      subject_id: assignment.principal_id,
      occurred_at: actor.at,
      correlation_id: Ash.UUID.generate(),
      payload_json: %{
        "role_assignment_id" => assignment.id,
        "role_definition_id" => definition.id,
        "role" => definition.key
      }
    })
    # REVIEWED-UNAUTHORIZED: audit append follows an authorized mutation.
    |> Ash.create!(authorize?: false, tenant: actor.tenant_id)
  end

  # A caller may have been authorized before it waited on this lock. The
  # assignment, organization and participant must still be active *after*
  # acquiring it; a cached actor must never authorize a new grant or revocation.
  defp serialized(actor, fun) do
    Dispatch.Repo.transaction(fn ->
      Dispatch.Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))", [
        "role-administration:" <> organization(actor)
      ])

      case PrincipalResolution.revalidate(actor) do
        {:ok, current_actor} ->
          case fun.(current_actor) do
            {:ok, result} -> result
            {:error, reason} -> Dispatch.Repo.rollback(reason)
          end

        {:error, _stale_authority} ->
          Dispatch.Repo.rollback(:not_found)
      end
    end)
  end

  defp organization(actor), do: actor.role_assignment.organization_id
end
