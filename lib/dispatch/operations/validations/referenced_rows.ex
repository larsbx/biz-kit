defmodule Dispatch.Operations.Validations.ReferencedRows do
  @moduledoc """
  A declaration may only point at rows the declaring participant owns.

  Section 24.1 states it for one of them — "Assignment, when supplied, belongs
  to the authenticated participant and active role assignment" — and Section
  22.3's uniqueness makes the other necessary. Both are the same mistake in two
  places: a foreign key copied from a request into a stored row without asking
  whether the caller had any claim to it.

  ## Why each matters

  An **assignment** scopes status history. Accepting one belonging to somebody
  else files this participant's declaration under another operator's trip. The
  sharper case is cross-tenant: a person holding authority in two organizations
  knows assignment IDs from both, and an unchecked reference links a tenant-A
  event to a tenant-B trip — a boundary nothing downstream re-checks.

  A **device sequence** is worse, because Section 22.3 makes
  `(device_id, device_sequence)` unique across *all* tenants. An unchecked
  device ID therefore lets any authenticated participant burn another device's
  sequence numbers, and Section 14's offline outbox would then find its own
  uploads rejected as duplicates by a stranger's writes. A revoked device
  (Section 13's lost-handset path) must not keep consuming them either.

  ## Where this lives

  On the action rather than in the controller, so a job or an agent tool
  invoking `:declare` is bound by it too. A rule that holds only on the path
  that happens to exist today is not a rule.

  Each lookup is scoped to the changeset's tenant and the acting participant, so
  a row in another tenant is not *rejected* — it is not found at all, by the
  same query that rejects one belonging to a different participant here. There
  is no branch on which kind of stranger owns it, and so no branch to get wrong.
  """

  use Ash.Resource.Validation

  alias Dispatch.Accounts.Device
  alias Dispatch.Fleet.Assignment

  require Ash.Query

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, context) do
    with :ok <- validate_assignment(changeset, context) do
      validate_device(changeset, context)
    end
  end

  @doc false
  @impl Ash.Resource.Validation
  def describe(_opts), do: [message: "must reference rows the declaring participant owns"]

  @impl Ash.Resource.Validation
  def atomic(changeset, opts, context),
    do: {:not_atomic, inspect(validate(changeset, opts, context))}

  defp validate_assignment(changeset, context) do
    case Ash.Changeset.get_attribute(changeset, :assignment_id) do
      nil ->
        :ok

      assignment_id ->
        Assignment
        |> Ash.Query.filter(
          id == ^assignment_id and operator_participant_id == ^participant(changeset) and
            status in [:PLANNED, :ACTIVE]
        )
        |> exists?(changeset, context)
        |> if(
          do: :ok,
          else:
            {:error,
             field: :assignment_id,
             message: "must be an open assignment operated by the declaring participant"}
        )
    end
  end

  defp validate_device(changeset, context) do
    case Ash.Changeset.get_attribute(changeset, :device_id) do
      nil ->
        :ok

      device_id ->
        Device
        |> Ash.Query.filter(
          id == ^device_id and participant_id == ^participant(changeset) and status == :ACTIVE
        )
        |> exists?(changeset, context)
        |> if(
          do: :ok,
          else:
            {:error,
             field: :device_id,
             message: "must be an active device registered to the declaring participant"}
        )
    end
  end

  # The declaring participant is read from the changeset, not from the actor.
  # `ActingOnSelf` has already established the two are the same, and taking it
  # from the row being written keeps this check about *that row* — it also holds
  # when the actor arrives at `Ash.create/2` rather than at changeset build
  # time, which is an ordinary calling convention and not something a
  # correctness check should depend on.
  defp participant(changeset), do: Ash.Changeset.get_attribute(changeset, :participant_id)

  # Both the tenant and the declaring participant are read from the row being
  # written rather than from the call. `Ash.create/2` may carry `tenant:` and
  # `actor:` that `Ash.Changeset.for_create/4` did not, and a correctness check
  # that silently inverts depending on which of two ordinary calling
  # conventions was used is worse than no check: it would pass every legitimate
  # request through the controller while rejecting every one from a job.
  #
  # Neither absent means fail: a write with no tenant or no declaring
  # participant should find nothing, not everything.
  defp exists?(query, changeset, context) do
    tenant = Ash.Changeset.get_attribute(changeset, :tenant_id)

    if is_nil(tenant) or is_nil(participant(changeset)) do
      false
    else
      read(query, tenant, context)
    end
  end

  # The actor is passed when there is one rather than the read being run
  # unauthorized. Neither resource carries policies today, so this changes
  # nothing now — but if either gains them, this lookup is checked along with
  # the rest instead of being the one place that quietly was not.
  defp read(query, tenant, context) do
    case Ash.read_one(query, actor: Map.get(context, :actor), tenant: tenant) do
      {:ok, nil} -> false
      {:ok, _row} -> true
      {:error, _reason} -> false
    end
  end
end
