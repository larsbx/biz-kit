defmodule Dispatch.Access.Actor do
  @moduledoc """
  Who is acting, under which single role assignment, at which instant.

  Section 23.3 requires that when a user holds several assignments, "every
  request selects or derives one active role assignment and records it in the
  audit event", and that the policy engine "MUST NOT union all capabilities
  merely because the assignments share a user".

  This struct makes that structural rather than conventional. It holds exactly
  one `role_assignment`, so a policy has nothing to union even if someone wanted
  to, and the field is not a list. Building an actor is the moment the selection
  happens, and it is the value the audit event records.

  `at` is carried rather than read from the clock, so a policy decision, the
  audit entry describing it, and a test asserting an expiry boundary all refer
  to the same instant.

  A `SERVICE` principal (Section 23.2) uses the same shape. It simply never
  holds a self-service capability — `Dispatch.Accounts.Validations.SelfServicePrincipal`
  refuses the grant — so the distinction is enforced where authority is
  assigned, not re-litigated on every check.
  """

  alias Dispatch.Accounts.RoleAssignment

  @enforce_keys [:principal_type, :principal_id, :tenant_id, :role_assignment, :at]
  defstruct [:principal_type, :principal_id, :tenant_id, :role_assignment, :at]

  @type t :: %__MODULE__{
          principal_type: :PARTICIPANT | :SERVICE,
          principal_id: Ash.UUID.t(),
          tenant_id: Ash.UUID.t(),
          role_assignment: RoleAssignment.t(),
          at: DateTime.t()
        }

  @doc """
  Builds an actor from one role assignment.

  The assignment must have its `role_definition` loaded: `Dispatch.Access`
  treats an unloaded definition as conferring nothing, so an actor built from a
  partial record would silently carry no capabilities rather than fail.
  """
  @spec from_assignment(RoleAssignment.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def from_assignment(%RoleAssignment{} = assignment, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())

    cond do
      not match?(%Dispatch.Accounts.RoleDefinition{}, assignment.role_definition) ->
        {:error, :role_definition_not_loaded}

      not Dispatch.Access.active_at?(assignment, at) ->
        {:error, :role_assignment_not_active}

      true ->
        {:ok,
         %__MODULE__{
           principal_type: assignment.principal_type,
           principal_id: assignment.principal_id,
           tenant_id: assignment.tenant_id,
           role_assignment: assignment,
           at: at
         }}
    end
  end

  @doc "Whether this actor carries `capability` at its own instant."
  @spec can?(t(), String.t()) :: boolean()
  def can?(%__MODULE__{} = actor, capability) do
    Dispatch.Access.can?(actor.role_assignment, capability, actor.at)
  end

  @doc "The capabilities this actor carries, sorted."
  @spec capabilities(t()) :: [String.t()]
  def capabilities(%__MODULE__{} = actor) do
    Dispatch.Access.capabilities(actor.role_assignment, actor.at)
  end

  @doc """
  Whether this actor is the participant `participant_id`.

  Section 23.2 attaches `self_only` to every driver capability, and acceptance
  criterion 1 makes a status a *declaration*: only the participant may make one
  about themselves.
  """
  @spec self?(t(), Ash.UUID.t()) :: boolean()
  def self?(%__MODULE__{principal_type: :PARTICIPANT} = actor, participant_id) do
    actor.principal_id == participant_id
  end

  def self?(_actor, _participant_id), do: false
end
