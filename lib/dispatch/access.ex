defmodule Dispatch.Access do
  @moduledoc """
  Capability resolution for one role assignment.

  Every authorization question in the system reduces to a question asked here:
  *does this assignment, in force at this instant, carry this capability, within
  this scope?* Section 23.2 forbids branching on a role key, so nothing in this
  module reads one.

  The API is deliberately singular. Section 23.3 states that when a user holds
  several assignments, every request selects or derives exactly one and records
  it in the audit event, and that the policy engine "MUST NOT union all
  capabilities merely because the assignments share a user". There is therefore
  no function here that accepts a list of assignments. Combining them would
  require an explicitly named policy rule with its own tests, which does not
  exist yet — and the absence of a convenient union function is what keeps one
  from being written by accident.

  Time is always an explicit argument. A policy check, a background job, and a
  test must be able to ask about the same instant; reading the clock internally
  would make an expiry-boundary test unwritable.
  """

  alias Dispatch.Access.{Capabilities, RoleProfile}
  alias Dispatch.Accounts.{RoleAssignment, RoleDefinition}

  @doc false
  @spec to_sorted_list(MapSet.t()) :: [Capabilities.t()]
  def to_sorted_list(set), do: set |> MapSet.to_list() |> Enum.sort()

  @typedoc "An assignment with its `role_definition` loaded."
  @type resolved_assignment :: RoleAssignment.t()

  @doc """
  Whether `assignment` is in force at `at`.

  An assignment is in force when it is `ACTIVE`, has started, and has not ended.
  Section 23.3 requires an expired or revoked assignment to fail closed across
  REST, Datastar, agent tools, jobs, and SSE reconnects alike, so this is the
  one predicate all of them consult.
  """
  @spec active_at?(RoleAssignment.t(), DateTime.t()) :: boolean()
  def active_at?(%RoleAssignment{} = assignment, %DateTime{} = at) do
    assignment.status == :ACTIVE and
      DateTime.compare(assignment.starts_at, at) != :gt and
      (is_nil(assignment.ends_at) or DateTime.compare(assignment.ends_at, at) == :gt)
  end

  def active_at?(_assignment, _at), do: false

  @doc """
  The capabilities a definition grants, sorted.

  Read through the definition's profile module, which Section 23.2 restricts to
  the compiled allowlist. A definition naming a module that is no longer
  allowlisted grants nothing: Section 31 fails startup in that state, and this
  is the runtime floor beneath it.

  Section 23.2 fixes the callback's return type as a `MapSet`; this module
  converts at that boundary and works in sorted lists thereafter. A capability
  bundle has at most a couple of dozen members, so set lookup buys nothing
  measurable, while `MapSet`'s opacity forces every caller and test to construct
  one to compare against.
  """
  @spec definition_capabilities(RoleDefinition.t()) :: [Capabilities.t()]
  def definition_capabilities(%RoleDefinition{} = definition) do
    case RoleProfile.fetch(definition.profile_module) do
      {:ok, module} -> definition |> module.capabilities() |> to_sorted_list()
      {:error, :profile_module_not_allowed} -> []
    end
  end

  def definition_capabilities(_definition), do: []

  @doc """
  The capabilities one assignment confers at `at`.

  Empty when the assignment is not in force, so an expired grant is
  indistinguishable from no grant at the point of decision.
  """
  @spec capabilities(resolved_assignment(), DateTime.t()) :: [Capabilities.t()]
  def capabilities(%RoleAssignment{} = assignment, %DateTime{} = at) do
    if active_at?(assignment, at) do
      case assignment.role_definition do
        %RoleDefinition{} = definition -> definition_capabilities(definition)
        # Not loaded means not proven. Failing closed here is the difference
        # between a forgotten `load` and a silent grant.
        _ -> []
      end
    else
      []
    end
  end

  def capabilities(_assignment, _at), do: []

  @doc """
  Whether one assignment carries `capability` at `at`.

  This is the question every policy check ultimately asks.
  """
  @spec can?(resolved_assignment(), Capabilities.t(), DateTime.t()) :: boolean()
  def can?(assignment, capability, %DateTime{} = at) do
    capability in capabilities(assignment, at)
  end

  @doc """
  Whether `assignment` covers `subject`.

  Scope narrows a capability to a subject; the capability alone never reaches
  past it. `SELF` and `ORGANIZATION` are bounded by the assignment's
  organization, so they match any subject the surrounding policy has already
  confined. `LOAD`, `STOP`, and `ASSIGNMENT` must name the subject exactly.

  A `true` here is necessary but never sufficient for a load or stop: Section
  22.2 additionally requires a matching active `load_parties` or `stop_parties`
  row. `Dispatch.Access.Party.permits?/4` is the conjunction of both halves and
  is what an authorization decision over a load or stop should call.
  """
  @spec in_scope?(RoleAssignment.t(), {atom(), Ash.UUID.t() | nil}) :: boolean()
  def in_scope?(%RoleAssignment{scope_type: scope_type}, {subject_type, _subject_id})
      when scope_type in [:SELF, :ORGANIZATION] and is_atom(subject_type),
      do: true

  def in_scope?(
        %RoleAssignment{scope_type: scope_type, scope_id: scope_id},
        {subject_type, subject_id}
      ) do
    scope_type == subject_type and not is_nil(scope_id) and scope_id == subject_id
  end

  def in_scope?(_assignment, _subject), do: false

  @doc """
  Whether `assignment` carries `capability` for `subject` at `at`.

  The conjunction the policy checks of Section 23.3 are built from: capability,
  scope, and validity at one instant, decided together.
  """
  @spec permits?(
          resolved_assignment(),
          Capabilities.t(),
          {atom(), Ash.UUID.t() | nil},
          DateTime.t()
        ) ::
          boolean()
  def permits?(assignment, capability, subject, %DateTime{} = at) do
    can?(assignment, capability, at) and in_scope?(assignment, subject)
  end

  @doc """
  The Android feature keys for an assignment.

  Section 23.2 requires the field application to enable features from a signed
  server capability document rather than an `if role == DRIVER` check, and
  Section 34's Slice 1 exit criterion makes that testable: no Android feature
  module may branch on a seeded role key. This is where the list comes from.
  """
  @spec android_features(resolved_assignment(), DateTime.t()) :: [String.t()]
  def android_features(%RoleAssignment{} = assignment, %DateTime{} = at) do
    with true <- active_at?(assignment, at),
         %RoleDefinition{} = definition <- assignment.role_definition,
         {:ok, module} <- RoleProfile.fetch(definition.profile_module) do
      module.android_features(assignment)
    else
      _ -> []
    end
  end

  def android_features(_assignment, _at), do: []

  @doc "The portal projection an assignment renders (Section 4.3)."
  @spec operations_projection(resolved_assignment()) :: atom()
  def operations_projection(
        %RoleAssignment{role_definition: %RoleDefinition{} = definition} = assignment
      ) do
    case RoleProfile.fetch(definition.profile_module) do
      {:ok, module} -> module.operations_projection(assignment)
      {:error, :profile_module_not_allowed} -> :none
    end
  end

  def operations_projection(_assignment), do: :none
end
