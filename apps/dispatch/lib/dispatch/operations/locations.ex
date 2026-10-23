defmodule Dispatch.Operations.Locations do
  @moduledoc """
  Consented location sharing (Sections 6.1, 24.2, 25.3).

  Sharing begins with a consent grant for one of the participant's own
  assignments and lasts for that assignment plus a grace period, or until the
  participant revokes it. Samples arrive in batches and each is judged on its
  own, so one bad sample never holds the rest back (Section 24.2's `207`):

    1. Its shape: fixed-point integers for coordinates and measurements (the
       canonical form a device signs has no floats).
    2. Its device signature: a sample is always signed by the participant's
       own registered device.
    3. Whether it is already stored: the same sample again is `DUPLICATE`;
       the same device sequence or ID carrying something else is refused.
    4. Its consent, *at the moment it was acquired*: the grant must be the
       participant's own, for the sample's assignment, and cover
       `occurred_at`. This is the revocation race: a sample acquired before
       revocation and uploaded after it is accepted; one acquired after is
       `REJECTED_CONSENT` (acceptance criterion 4).
    5. Its clock: `occurred_at` may not lie in the future beyond the same
       five-minute bound declarations have. This is the "known skew bound" a
       signed acquisition time is trusted within.
  """

  require Ash.Query

  import Ecto.Query, only: [from: 2]

  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.DeviceKeys
  alias Dispatch.Audit.AuditEvent
  alias Dispatch.Fleet.Assignment
  alias Dispatch.Operations.{ConsentGrant, LocationSample, StreamRefresh}

  @max_batch 100
  @max_skew_ms 300_000
  @default_grace_seconds 1_800

  @type result :: %{sample_id: String.t() | nil, result: String.t(), code: String.t() | nil}

  @doc "The most samples one batch may carry (Section 24.2)."
  @spec max_batch() :: pos_integer()
  def max_batch, do: @max_batch

  @doc """
  Begins sharing for `assignment_id`, one of the actor's own planned or active
  assignments. Consenting again while a grant still covers now returns it.
  """
  @spec begin_consent(Actor.t(), String.t()) ::
          {:ok, struct()} | {:error, :not_found | :forbidden}
  def begin_consent(%Actor{} = actor, assignment_id) do
    with :ok <- may_share(actor),
         {:ok, id} <- uuid(assignment_id) do
      with_trip_lock(actor.tenant_id, id, fn ->
        # Read both the assignment and the current grant after taking the lock.
        # Completion/cancellation updates this same row before closing grants.
        with {:ok, assignment} <- own_assignment(actor, id) do
          case current_grant(actor, id) do
            nil -> create_grant(actor, assignment)
            grant -> {:ok, grant}
          end
        end
      end)
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Revokes one of the actor's own grants. Revoking a revoked grant returns it as it is."
  @spec revoke_consent(Actor.t(), String.t()) ::
          {:ok, struct()} | {:error, :not_found | :forbidden}
  def revoke_consent(%Actor{} = actor, grant_id) do
    with :ok <- may_share(actor),
         {:ok, grant} <- own_grant(actor, grant_id) do
      with_trip_lock(actor.tenant_id, grant.scope_json["assignment_id"], fn ->
        # The initial lookup only identifies the trip. Re-read under its lock:
        # a waiting revocation must see everything the preceding begin committed.
        with {:ok, current} <- own_grant(actor, grant_id) do
          if current.revoked_at do
            {:ok, current}
          else
            revoked =
              actor
              |> grants()
              |> Enum.filter(&(is_nil(&1.revoked_at) and same_trip?(&1, current)))
              |> Enum.map(&revoke!(actor, &1))

            StreamRefresh.enqueue!(actor, actor.principal_id, "location_consent.revoked", %{
              "grant_id" => current.id
            })

            {:ok, Enum.find(revoked, &(&1.id == current.id))}
          end
        end
      end)
    end
  end

  # A database row lock works across nodes and across different idempotency
  # keys. Keep reads, mutations and audit/outbox writes in the same transaction.
  defp with_trip_lock(tenant_id, assignment_id, fun) do
    {:ok, result} =
      Dispatch.Repo.transaction(fn ->
        from(a in "assignments",
          where:
            a.id == type(^assignment_id, :binary_id) and
              a.tenant_id == type(^tenant_id, :binary_id),
          select: a.id,
          lock: "FOR UPDATE"
        )
        |> Dispatch.Repo.one()
        |> case do
          nil -> {:error, :not_found}
          _id -> fun.()
        end
      end)

    result
  end

  @doc """
  Ends `trip`'s location consents at its end plus grace, when that is sooner
  than they would have. Run as the trip completes or is cancelled; system
  work, not any participant's request.
  """
  @spec close_consents(struct()) :: :ok
  def close_consents(%Assignment{ends_at: %DateTime{}} = trip) do
    closes = window_end(trip)

    ConsentGrant
    |> Ash.Query.filter(kind == :LOCATION_SHARING and is_nil(revoked_at))
    # REVIEWED-UNAUTHORIZED: the trip's own end closes its consents; no
    # participant acts, and nothing read leaves this function.
    |> Ash.read!(authorize?: false, tenant: trip.tenant_id)
    |> Enum.filter(&(&1.scope_json["assignment_id"] == trip.id))
    |> Enum.filter(&(is_nil(&1.expires_at) or DateTime.compare(&1.expires_at, closes) == :gt))
    |> Enum.each(fn grant ->
      grant
      |> Ash.Changeset.for_update(:close_location_consent, %{expires_at: closes})
      |> Ash.update!(authorize?: false, tenant: trip.tenant_id)
    end)
  end

  def close_consents(_trip_without_an_end), do: :ok

  @doc "Ingests a batch, one result per sample, in the order sent."
  @spec ingest(Actor.t(), [map()]) :: {:ok, [result()]} | {:error, :forbidden | :batch_too_large}
  def ingest(%Actor{}, samples) when length(samples) > @max_batch, do: {:error, :batch_too_large}

  def ingest(%Actor{} = actor, samples) when is_list(samples) do
    with :ok <- may_share(actor) do
      results = Enum.map(samples, &ingest_one(actor, &1))

      if Enum.any?(results, &(&1.result == "ACCEPTED")) do
        StreamRefresh.enqueue!(actor, actor.principal_id, "location.sampled", %{})
      end

      {:ok, results}
    end
  end

  defp ingest_one(actor, raw) do
    sample_id = if is_map(raw), do: raw["sample_id"]

    outcome =
      with {:ok, sample} <- parse(raw),
           :ok <- signed(actor, raw),
           :new <- stored(actor, sample),
           {:ok, grant} <- consent(actor, sample),
           :ok <- clock(sample) do
        insert(actor, sample, grant)
      end

    case outcome do
      :ok -> %{sample_id: sample_id, result: "ACCEPTED", code: nil}
      :duplicate -> %{sample_id: sample_id, result: "DUPLICATE", code: nil}
      {:error, code} -> %{sample_id: sample_id, result: "REJECTED", code: code}
    end
  end

  defp may_share(actor),
    do: if(Actor.can?(actor, "location.share.self"), do: :ok, else: {:error, :forbidden})

  # -- Consent ------------------------------------------------------------------

  defp own_assignment(actor, id) do
    with {:ok, id} <- uuid(id),
         {:ok, %Assignment{operator_participant_id: operator} = assignment} <-
           Ash.get(Assignment, id, authorize?: false, tenant: actor.tenant_id),
         true <- operator == actor.principal_id,
         true <- Assignment.open?(assignment, DateTime.utc_now()) do
      {:ok, assignment}
    else
      _not_theirs -> {:error, :not_found}
    end
  end

  defp current_grant(actor, assignment_id), do: Map.get(covering(actor), assignment_id)

  @doc """
  The actor's own location consents covering now, by the assignment each is
  for. At most one covers an assignment: `begin_consent/2` returns it rather
  than granting another.
  """
  @spec covering(Actor.t()) :: %{Ash.UUID.t() => struct()}
  def covering(%Actor{} = actor) do
    now = DateTime.utc_now()

    actor
    |> grants()
    |> Enum.filter(&ConsentGrant.covers?(&1, now))
    |> Map.new(&{&1.scope_json["assignment_id"], &1})
  end

  defp own_grant(actor, id) do
    case uuid(id) do
      {:ok, id} ->
        case Enum.find(grants(actor), &(&1.id == id)) do
          nil -> {:error, :not_found}
          grant -> {:ok, grant}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp grants(actor) do
    ConsentGrant
    |> Ash.Query.filter(participant_id == ^actor.principal_id and kind == :LOCATION_SHARING)
    |> Ash.read!(actor: actor, tenant: actor.tenant_id)
  end

  defp same_trip?(a, b), do: a.scope_json["assignment_id"] == b.scope_json["assignment_id"]

  defp revoke!(actor, grant) do
    revoked =
      grant
      |> Ash.Changeset.for_update(:revoke_location_consent, %{},
        actor: actor,
        tenant: actor.tenant_id
      )
      |> Ash.update!()

    audit!(actor, "location_consent.revoked", revoked)
    revoked
  end

  defp create_grant(actor, assignment) do
    grant =
      ConsentGrant
      |> Ash.Changeset.for_create(
        :begin_location_consent,
        %{
          tenant_id: actor.tenant_id,
          participant_id: actor.principal_id,
          role_assignment_id: actor.role_assignment.id,
          scope_json: %{"assignment_id" => assignment.id},
          expires_at: window_end(assignment)
        },
        actor: actor,
        tenant: actor.tenant_id
      )
      |> Ash.create!()

    audit!(actor, "location_consent.granted", grant)
    {:ok, grant}
  end

  # Section 6.1: the active assignment plus a configurable grace period.
  defp window_end(%Assignment{ends_at: nil}), do: nil

  defp window_end(%Assignment{ends_at: ends_at}) do
    grace = Application.get_env(:dispatch, :location_grace_seconds, @default_grace_seconds)
    DateTime.add(ends_at, grace, :second)
  end

  # -- Samples ------------------------------------------------------------------

  defp parse(raw) when is_map(raw) do
    with {:ok, id} <- field(raw, "sample_id", :uuid),
         {:ok, assignment_id} <- field(raw, "assignment_id", :uuid),
         {:ok, lat} <- field(raw, "lat_e7", {:range, -900_000_000..900_000_000}),
         {:ok, lng} <- field(raw, "lng_e7", {:range, -1_800_000_000..1_800_000_000}),
         {:ok, accuracy} <- field(raw, "accuracy_cm", :count),
         {:ok, speed} <- optional(raw, "speed_cmps", :count),
         {:ok, bearing} <- optional(raw, "bearing_cdeg", {:range, 0..36_000}),
         {:ok, provider} <- field(raw, "provider", :provider),
         {:ok, mock} <- field(raw, "is_mock", :boolean),
         {:ok, occurred_at} <- field(raw, "occurred_at", :instant),
         {:ok, device_id} <- field(raw, "device_id", :uuid),
         {:ok, sequence} <- field(raw, "device_sequence", :count),
         {:ok, grant_id} <- field(raw, "consent_grant_id", :uuid) do
      {:ok,
       %{
         id: id,
         assignment_id: assignment_id,
         position: {lng / 10_000_000, lat / 10_000_000},
         accuracy_m: accuracy / 100,
         speed_mps: speed && speed / 100,
         bearing_deg: bearing && bearing / 100,
         provider: provider,
         is_mock: mock,
         occurred_at: occurred_at,
         device_id: device_id,
         device_sequence: sequence,
         consent_grant_id: grant_id
       }}
    end
  end

  defp parse(_not_a_sample), do: {:error, "INVALID_SAMPLE"}

  defp optional(raw, key, kind),
    do: if(Map.get(raw, key) == nil, do: {:ok, nil}, else: field(raw, key, kind))

  defp field(raw, key, kind) do
    case cast(kind, Map.get(raw, key)) do
      {:ok, value} -> {:ok, value}
      _invalid -> {:error, "INVALID_SAMPLE"}
    end
  end

  defp cast(:uuid, value) when is_binary(value), do: Ecto.UUID.cast(value)

  defp cast({:range, first..last//1}, value)
       when is_integer(value) and value >= first and value <= last,
       do: {:ok, value}

  defp cast(:count, value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp cast(:provider, value) when is_binary(value) and byte_size(value) in 1..32,
    do: {:ok, value}

  defp cast(:boolean, value) when is_boolean(value), do: {:ok, value}

  defp cast(:instant, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _invalid -> :error
    end
  end

  defp cast(_kind, _value), do: :error

  defp uuid(value), do: cast(:uuid, value)

  defp signed(actor, raw) do
    case DeviceKeys.verify_sample(
           actor,
           Map.delete(raw, "device_signature"),
           raw["device_signature"]
         ) do
      :ok -> :ok
      {:error, :device_signature_required} -> {:error, "DEVICE_SIGNATURE_REQUIRED"}
      {:error, :device_signature_invalid} -> {:error, "DEVICE_SIGNATURE_INVALID"}
    end
  end

  # Across tenants, like the unique index it answers for; only the verdict
  # leaves this function.
  defp stored(_actor, sample) do
    from(s in "location_samples",
      where:
        s.id == type(^sample.id, :binary_id) or
          (s.device_id == type(^sample.device_id, :binary_id) and
             s.device_sequence == ^sample.device_sequence),
      select: %{
        id: type(s.id, :binary_id),
        device_id: type(s.device_id, :binary_id),
        device_sequence: s.device_sequence,
        contents: {
          type(s.assignment_id, :binary_id),
          type(s.consent_grant_id, :binary_id),
          fragment("ST_X(?::geometry)", s.position),
          fragment("ST_Y(?::geometry)", s.position),
          s.accuracy_m,
          s.speed_mps,
          s.bearing_deg,
          s.provider,
          s.is_mock,
          type(s.occurred_at, :utc_datetime_usec)
        }
      }
    )
    # REVIEWED-UNAUTHORIZED: whether this sample ID or device sequence is taken.
    |> Dispatch.Repo.all()
    |> case do
      [] ->
        :new

      # The same sample only if it says the same thing: identifiers carrying
      # anything else would be discarded by the device as already stored.
      [%{id: id, device_id: device, device_sequence: sequence, contents: contents}]
      when id == sample.id and device == sample.device_id and
             sequence == sample.device_sequence ->
        if same_contents?(contents, sample),
          do: :duplicate,
          else: {:error, "DEVICE_SEQUENCE_CONFLICT"}

      _taken ->
        {:error, "DEVICE_SEQUENCE_CONFLICT"}
    end
  end

  defp same_contents?(
         {assignment, grant, lng, lat, accuracy, speed, bearing, provider, mock, at},
         sample
       ) do
    {sample_lng, sample_lat} = sample.position

    {assignment, grant, lng, lat, accuracy, speed, bearing, provider, mock} ==
      {sample.assignment_id, sample.consent_grant_id, sample_lng, sample_lat, sample.accuracy_m,
       sample.speed_mps, sample.bearing_deg, sample.provider, sample.is_mock} and
      DateTime.compare(at, sample.occurred_at) == :eq
  end

  defp consent(actor, sample) do
    with {:ok, grant} <- own_grant(actor, sample.consent_grant_id),
         true <- grant.scope_json["assignment_id"] == sample.assignment_id,
         true <- ConsentGrant.covers?(grant, sample.occurred_at) do
      {:ok, grant}
    else
      _not_covered -> {:error, "REJECTED_CONSENT"}
    end
  end

  defp clock(sample) do
    if DateTime.diff(sample.occurred_at, DateTime.utc_now(), :millisecond) > @max_skew_ms,
      do: {:error, "CLOCK_SKEW"},
      else: :ok
  end

  defp insert(actor, sample, grant) do
    LocationSample
    |> Ash.Changeset.for_create(
      :ingest_location_sample,
      Map.merge(sample, %{
        tenant_id: actor.tenant_id,
        participant_id: actor.principal_id,
        role_assignment_id: grant.role_assignment_id
      }),
      actor: actor,
      tenant: actor.tenant_id
    )
    |> Ash.create()
    |> case do
      {:ok, _sample} -> :ok
      # Another copy of the batch won the unique index in between.
      {:error, _error} -> {:error, "DEVICE_SEQUENCE_CONFLICT"}
    end
  end

  defp audit!(actor, event_type, grant) do
    AuditEvent
    |> Ash.Changeset.for_create(:record, %{
      tenant_id: actor.tenant_id,
      event_type: event_type,
      actor_type: actor.principal_type,
      actor_id: actor.principal_id,
      role_assignment_id: actor.role_assignment.id,
      subject_type: "participant",
      subject_id: actor.principal_id,
      occurred_at: DateTime.utc_now(),
      correlation_id: Ash.UUID.generate(),
      payload_json: %{
        "grant_id" => grant.id,
        "assignment_id" => grant.scope_json["assignment_id"]
      }
    })
    # REVIEWED-UNAUTHORIZED: audit append follows an authorized mutation.
    |> Ash.create!(authorize?: false, tenant: actor.tenant_id)
  end
end
