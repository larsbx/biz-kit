defmodule Dispatch.Access.Driving do
  @moduledoc """
  Who may drive for an organization, and whether their equipment is out.

  A role drives when it carries `assignment.read.self`, the capability the
  board plans trips with; no role key is read (Section 23.2).

  Owner rule (2026-11-02): a driver's role ends only once their equipment is
  checked in, meaning no active trip of theirs in the organization holds a
  vehicle or trailer. Two writers keep that rule, and they serialize on the
  trip rows:

  - Revoking a driving role locks the participant's open trips `FOR UPDATE`
    (`equipment_out?/3`) before deciding.
  - Activating a trip locks that trip, then locks the operator's driving roles
    `FOR SHARE` (`roles/4` with `lock: true`).

  Whichever commits first, the other sees it: a revocation finds the active
  trip, or an activation finds no driving role. Both take the trip lock before
  any role row, so the two cannot deadlock.
  """

  import Ecto.Query, only: [from: 2]

  alias Dispatch.Accounts.RoleAssignment

  require Ash.Query

  @capability "assignment.read.self"

  @doc "The capability that makes a role a driving one."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "Whether `assignment` lets its holder drive at `at`."
  @spec drives?(RoleAssignment.t(), DateTime.t()) :: boolean()
  def drives?(assignment, at), do: Dispatch.Access.can?(assignment, @capability, at)

  @doc """
  `participant_id`'s driving roles in `organization_id`, in force now. With
  `lock: true`, inside a transaction, the rows are first locked `FOR SHARE`.
  """
  @spec roles(Ash.UUID.t(), Ash.UUID.t(), Ash.UUID.t(), keyword()) :: [RoleAssignment.t()]
  def roles(tenant, organization_id, participant_id, opts \\ []) do
    if Keyword.get(opts, :lock, false) do
      from(ra in "role_assignments",
        where: ra.tenant_id == type(^tenant, :binary_id),
        where: ra.organization_id == type(^organization_id, :binary_id),
        where: ra.principal_id == type(^participant_id, :binary_id),
        where: ra.principal_type == "PARTICIPANT",
        select: ra.id,
        lock: "FOR SHARE"
      )
      |> Dispatch.Repo.all()
    end

    at = DateTime.utc_now()

    RoleAssignment
    |> Ash.Query.for_read(:active, %{at: at})
    |> Ash.Query.filter(
      organization_id == ^organization_id and principal_id == ^participant_id and
        principal_type == :PARTICIPANT
    )
    |> Ash.Query.load(:role_definition)
    # REVIEWED-UNAUTHORIZED: whether a participant may drive, for a writer that
    # has already authorized its actor; no assignment leaves the caller.
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.filter(&drives?(&1, at))
  end

  @doc """
  Whether `participant_id` has an active trip in `organization_id` holding a
  vehicle or trailer. Locks the participant's open trips `FOR UPDATE` first,
  so call it inside the transaction that acts on the answer.
  """
  @spec equipment_out?(Ash.UUID.t(), Ash.UUID.t(), Ash.UUID.t()) :: boolean()
  def equipment_out?(tenant, organization_id, participant_id) do
    carried =
      from(l in "loads",
        where: l.tenant_id == type(^tenant, :binary_id),
        where: l.carrier_organization_id == type(^organization_id, :binary_id),
        select: l.id
      )

    from(a in "assignments",
      where: a.tenant_id == type(^tenant, :binary_id),
      where: a.operator_participant_id == type(^participant_id, :binary_id),
      where: a.status in ["PLANNED", "ACTIVE"],
      where: a.load_id in subquery(carried),
      order_by: a.id,
      select: %{status: a.status, equipped: not is_nil(a.vehicle_id) or not is_nil(a.trailer_id)},
      lock: "FOR UPDATE"
    )
    |> Dispatch.Repo.all()
    |> Enum.any?(&(&1.status == "ACTIVE" and &1.equipped))
  end
end
