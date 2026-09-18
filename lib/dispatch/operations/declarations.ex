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
          | {:error, Ash.Error.t()}

  @accepted ~w(status occurred_at note assignment_id location_sample_id
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
      |> Map.merge(%{
        tenant_id: actor.tenant_id,
        participant_id: actor.principal_id,
        role_assignment_id: actor.role_assignment.id
      })

    case existing(actor, input) do
      nil -> create(actor, input)
      event -> reconcile(event, input)
    end
  end

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
          nil -> {:error, error}
          event -> reconcile(event, input)
        end
    end
  end

  defp reconcile(event, input) do
    if identifying(event) == identifying(input) do
      {:ok, :duplicate, event}
    else
      {:error, :device_sequence_conflict}
    end
  end

  # A declaration without a device sequence cannot duplicate one: Section 22.3's
  # uniqueness is on the pair, and a portal declaration carries neither.
  defp existing(_actor, %{device_id: nil}), do: nil
  defp existing(_actor, %{device_sequence: nil}), do: nil

  defp existing(actor, %{device_id: device_id, device_sequence: sequence}) do
    ParticipantStatusEvent
    |> Ash.Query.filter(device_id == ^device_id and device_sequence == ^sequence)
    |> Ash.read_one(actor: actor, tenant: actor.tenant_id)
    |> case do
      {:ok, event} -> event
      # A sequence taken in another tenant is invisible here, and must stay so.
      # Returning nil lets the write attempt fail on the index, which surfaces
      # as an error rather than as a cross-tenant disclosure.
      {:error, _reason} -> nil
    end
  end

  defp existing(_actor, _no_device), do: nil

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
