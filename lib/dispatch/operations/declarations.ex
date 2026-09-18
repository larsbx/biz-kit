defmodule Dispatch.Operations.Declarations do
  @moduledoc """
  Recording a participant's status declaration (Section 24.1).

  The controller calls this; Section 21.1 keeps transport out of it and it keeps
  domain reasoning out of the controller. The two routes of Section 24.1 —
  canonical `/v1/me/status-events` and the `DRIVER` compatibility projection
  `/v1/driver/status-events` — both land here, which is what makes them produce
  the same participant-scoped event rather than two code paths that happen to
  agree today.

  ## The participant is never a parameter

  Section 24.1: "Both invoke the same Ash action with the authenticated
  `participant_id` and active `role_assignment_id`; neither accepts an arbitrary
  participant identifier." So `declare/2` derives both from the actor and
  silently has no way to accept them from a request — not a validation that
  rejects a supplied ID, but no parameter at all.

  ## Duplicate device sequences

  Section 24.1: a duplicate device sequence with the same hash returns the
  original `201` body; a different hash returns `409 DEVICE_SEQUENCE_CONFLICT`.

  "The same hash" is judged over the *declaration* — status, time, note, the
  rows it refers to — rather than over the raw request. A handset that retries
  after a lost response may legitimately resend with a different correlation ID
  or header set, and that is the same declaration; changing the status under a
  sequence number already used is not, whatever else matches.
  """

  alias Dispatch.Access.Actor
  alias Dispatch.Operations.ParticipantStatusEvent

  require Ash.Query

  @typedoc "Fields a caller may supply. Identity and authority are not among them."
  @type attrs :: %{optional(atom()) => term()}

  @typedoc "A new declaration, a replay of one already recorded, or a refusal."
  @type result ::
          {:ok, :created, ParticipantStatusEvent.t()}
          | {:ok, :duplicate, ParticipantStatusEvent.t()}
          | {:error, :device_sequence_conflict}
          | {:error, :event_id_conflict}
          | {:error, Ash.Error.t()}

  @accepted ~w(id status occurred_at note assignment_id location_sample_id
               supersedes_event_id device_id device_sequence correlation_id)a

  # What makes two declarations the same declaration. Deliberately excludes
  # `correlation_id` and every server-assigned field: a retry is a retry even
  # when the transport around it differs.
  @identifying ~w(participant_id status occurred_at note assignment_id
                  location_sample_id supersedes_event_id)a

  @doc """
  Records `attrs` as a declaration by `actor` about themselves.

  Returns `{:ok, :duplicate, event}` when this device sequence already carries
  the same declaration, so a caller that lost the first response gets the first
  event back rather than a second one.
  """
  @spec declare(Actor.t(), attrs()) :: result()
  def declare(%Actor{} = actor, attrs) do
    input =
      attrs
      |> Map.take(@accepted)
      # An absent client ID must leave the attribute unset so the resource's own
      # UUIDv7 generator supplies one. Passing an explicit `nil` would override
      # the default and fail on `allow_nil?` instead.
      |> Map.reject(fn {key, value} -> key == :id and is_nil(value) end)
      |> Map.merge(%{
        tenant_id: actor.tenant_id,
        participant_id: actor.principal_id,
        role_assignment_id: actor.role_assignment.id
      })

    case existing(actor, input) do
      nil -> create(actor, input)
      {matched_on, event} -> reconcile(matched_on, event, input)
    end
  end

  @doc """
  The declaration this actor already recorded under `event_id`, if any.

  Section 24.1 calls the ID client-assigned, which only means something if a
  replay under the same ID resolves to the same event. The lookup is scoped to
  the actor's own records, so a guessed ID belonging to somebody else is not
  found and the write then fails on the primary key rather than disclosing that
  the row exists.
  """
  @spec by_id(Actor.t(), Ash.UUID.t()) :: ParticipantStatusEvent.t() | nil
  def by_id(%Actor{} = actor, event_id) when is_binary(event_id) do
    ParticipantStatusEvent
    |> Ash.Query.filter(id == ^event_id and participant_id == ^actor.principal_id)
    |> Ash.read_one(actor: actor, tenant: actor.tenant_id)
    |> case do
      {:ok, event} -> event
      {:error, _reason} -> nil
    end
  end

  def by_id(_actor, _event_id), do: nil

  defp create(actor, input) do
    ParticipantStatusEvent
    |> Ash.Changeset.for_create(:declare, input, actor: actor, tenant: actor.tenant_id)
    |> Ash.create()
    |> case do
      {:ok, event} ->
        {:ok, :created, event}

      {:error, error} ->
        # Another copy of the same request won the unique index between the read
        # above and this write. Re-reading is what turns that race into the
        # replay Section 24.1 specifies rather than a spurious error.
        case existing(actor, input) do
          nil -> classify(error, input)
          {matched_on, event} -> reconcile(matched_on, event, input)
        end
    end
  end

  # The ID is taken, and the lookup above — scoped to this participant's own
  # records — did not find it, so it belongs to somebody else. That is a
  # conflict, not a validation failure, and the caller learns only that: whose
  # event it is stays out of the response.
  defp classify(error, %{id: event_id}) when is_binary(event_id) do
    if Enum.any?(errors(error), &(Map.get(&1, :field) == :id)) do
      {:error, :event_id_conflict}
    else
      {:error, error}
    end
  end

  defp classify(error, _no_client_id), do: {:error, error}

  defp errors(%{errors: errors}) when is_list(errors), do: errors
  defp errors(_error), do: []

  # Which lookup found the row decides which conflict this is. Reporting a
  # device-sequence conflict for a request that carried no device would send a
  # client looking at a field it never sent.
  defp reconcile(matched_on, event, input) do
    if identifying(event) == identifying(input) do
      {:ok, :duplicate, event}
    else
      {:error, conflict_for(matched_on)}
    end
  end

  defp conflict_for(:id), do: :event_id_conflict
  defp conflict_for(:device_sequence), do: :device_sequence_conflict

  # Two ways a declaration can already exist: the client named its ID, or the
  # device sequence pins it. The ID is checked first because it is exact —
  # Section 24.1 makes it the client's own handle on the event.
  defp existing(actor, %{id: event_id} = input) when is_binary(event_id) do
    case by_id(actor, event_id) do
      nil -> by_device_sequence(actor, input)
      event -> {:id, event}
    end
  end

  defp existing(actor, input), do: by_device_sequence(actor, input)

  # A declaration without a device sequence cannot duplicate one: Section 22.3's
  # uniqueness is on the pair, and a portal declaration carries neither.
  defp by_device_sequence(_actor, %{device_id: nil}), do: nil
  defp by_device_sequence(_actor, %{device_sequence: nil}), do: nil

  defp by_device_sequence(actor, %{device_id: device_id, device_sequence: sequence}) do
    ParticipantStatusEvent
    |> Ash.Query.filter(device_id == ^device_id and device_sequence == ^sequence)
    |> Ash.read_one(actor: actor, tenant: actor.tenant_id)
    |> case do
      {:ok, nil} -> nil
      {:ok, event} -> {:device_sequence, event}
      # A sequence taken in another tenant is invisible here, and must stay so.
      # Returning nil lets the write attempt fail on the index, which surfaces
      # as an error rather than as a cross-tenant disclosure.
      {:error, _reason} -> nil
    end
  end

  defp by_device_sequence(_actor, _no_device), do: nil

  defp identifying(%ParticipantStatusEvent{} = event) do
    event |> Map.from_struct() |> identifying()
  end

  defp identifying(%{} = attrs) do
    Map.new(@identifying, fn field -> {field, normalise(Map.get(attrs, field))} end)
  end

  # A status arrives as a string from JSON and is stored as an atom; a timestamp
  # arrives with second precision and is stored with microsecond. Comparing the
  # raw values would report a retry as a conflict.
  defp normalise(%DateTime{} = at), do: DateTime.truncate(at, :millisecond)
  defp normalise(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp normalise(value), do: value
end
