defmodule Dispatch.Access.Party do
  @moduledoc """
  The second half of a `LOAD`- or `STOP`-scoped authorization decision.

  Section 22.2 states the rule this module exists for:

  > `LOAD`- and `STOP`-scoped authorization requires both an active
  > `role_assignment` and a matching active `load_parties` or `stop_parties`
  > relationship. A contact record, phone number, email address, organization
  > kind, or caller claim never grants access by itself.

  The two halves expire independently, which is the whole point. A broker's role
  assignment may remain valid long after its contract on a particular load
  ended, and acceptance criterion 19 requires an unrelated load to return no
  existence-bearing metadata — not a denial that confirms the load exists.
  Acceptance criterion 15 requires removing the relationship to terminate REST,
  page and SSE access immediately, so the check reads present state and never a
  cached grant.

  `Dispatch.Access` answers "does this assignment carry this capability over
  this scope". This module answers "is this organization still party to that
  subject". Both must be true; neither is sufficient.
  """

  alias Dispatch.Fleet.{LoadParty, StopParty}

  require Ash.Query

  @typedoc "The relationships that may be required of a party."
  @type relationship :: :BROKER | :SHIPPER | :RECEIVER | :CARRIER | :FACILITY

  @doc """
  Whether `organization_id` is party to `load_id` at `at`.

  `relationships` narrows the kinds that count; `:any` accepts every kind. A
  shipper party row on a load does not make its holder a broker, so a check
  that cares which one must say so.
  """
  @spec party_to_load?(Ash.UUID.t(), Ash.UUID.t(), keyword()) :: boolean()
  def party_to_load?(load_id, organization_id, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())
    relationships = Keyword.get(opts, :relationships, :any)
    tenant = Keyword.fetch!(opts, :tenant)

    LoadParty
    |> Ash.Query.for_read(:active, %{at: at}, tenant: tenant)
    |> Ash.Query.filter(load_id == ^load_id and organization_id == ^organization_id)
    |> narrow(relationships)
    |> exists?()
  end

  @doc "Whether `organization_id` is party to `stop_id` at `at`."
  @spec party_to_stop?(Ash.UUID.t(), Ash.UUID.t(), keyword()) :: boolean()
  def party_to_stop?(stop_id, organization_id, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())
    relationships = Keyword.get(opts, :relationships, :any)
    tenant = Keyword.fetch!(opts, :tenant)

    StopParty
    |> Ash.Query.for_read(:active, %{at: at}, tenant: tenant)
    |> Ash.Query.filter(stop_id == ^stop_id and organization_id == ^organization_id)
    |> narrow(relationships)
    |> exists?()
  end

  @doc """
  Whether an assignment permits `capability` over `subject`, party included.

  The conjunction Section 22.2 requires: the assignment must carry the
  capability, its scope must cover the subject, *and* — for a load or a stop —
  the assignment's organization must still be party to it.

  A `SELF` or `ORGANIZATION` scope needs no party row, because the organization
  is the bound. Passing a load or stop subject with such a scope is therefore
  allowed here and confined by the surrounding query instead.
  """
  @spec permits?(
          Dispatch.Accounts.RoleAssignment.t(),
          String.t(),
          {atom(), Ash.UUID.t()},
          keyword()
        ) ::
          boolean()
  def permits?(assignment, capability, subject, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())

    Dispatch.Access.permits?(assignment, capability, subject, at) and
      party_satisfied?(assignment, subject, opts)
  end

  defp party_satisfied?(assignment, {:LOAD, load_id}, opts) do
    party_to_load?(load_id, assignment.organization_id,
      at: Keyword.get(opts, :at, DateTime.utc_now()),
      relationships: Keyword.get(opts, :relationships, :any),
      tenant: assignment.tenant_id
    )
  end

  defp party_satisfied?(assignment, {:STOP, stop_id}, opts) do
    party_to_stop?(stop_id, assignment.organization_id,
      at: Keyword.get(opts, :at, DateTime.utc_now()),
      relationships: Keyword.get(opts, :relationships, :any),
      tenant: assignment.tenant_id
    )
  end

  # Other subject kinds carry no party relationship; the scope check already
  # decided them.
  defp party_satisfied?(_assignment, _subject, _opts), do: true

  defp narrow(query, :any), do: query

  defp narrow(query, relationships) when is_list(relationships) do
    Ash.Query.filter(query, relationship in ^relationships)
  end

  defp narrow(query, relationship) when is_atom(relationship) do
    Ash.Query.filter(query, relationship == ^relationship)
  end

  # REVIEWED-UNAUTHORIZED: this is an authorization primitive, so it must read
  # the relationship with the service's own authority. Subjecting it to the
  # actor's read policy would make the check unevaluable for exactly the actors
  # it governs, and an unevaluable authorization check either denies everyone or
  # — far worse — is written to allow. No row is returned to the caller; only
  # the boolean leaves this module.
  defp exists?(query) do
    case Ash.read(query, authorize?: false) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end
end
