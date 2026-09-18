defmodule Dispatch.Idempotency do
  @moduledoc """
  The `Idempotency-Key` ledger of Section 24.

  > Every mutation accepts `Idempotency-Key`. The server stores the key, actor,
  > request hash, response status, and response body for 24 hours. Reuse with a
  > different request hash returns `409 IDEMPOTENCY_KEY_REUSED`.

  ## Why a reservation rather than a lookup

  The obvious implementation — look for a stored response, run the mutation if
  there is none, store the result — has a race exactly where it matters. Two
  copies of the same request arriving together both find nothing and both run.
  A handset retrying over a flaky link is the *normal* case here (Section 14's
  offline outbox), so that race is not hypothetical.

  So the key is claimed first, in one `INSERT ... ON CONFLICT DO NOTHING`. The
  request that wins the insert runs the mutation; anything else sees a row and
  is answered from it. The claim and the stored response are the same row, so
  there is no window in which a key is taken but unrecorded.

  ## What "the same request" means

  The hash is over the caller's own body, so replaying a request returns the
  first response, while reusing a key for *different* content is refused rather
  than silently answered with someone else's result. The key is scoped to the
  role assignment as well as the tenant: Section 23.3 makes the assignment the
  unit of authority, so two actors choosing the same key string is a collision
  with no meaning, not a replay.
  """

  import Ecto.Query, only: [from: 2]

  alias Dispatch.Access.Actor
  alias Dispatch.Idempotency.Record

  @retention_hours 24

  @typedoc "A claim outcome: run the mutation, or answer from the ledger."
  @type claim ::
          {:proceed, claim_id :: Ash.UUID.t()}
          | {:replay, status :: pos_integer(), body :: map()}
          | {:error, :key_reused}
          | {:error, :in_progress}

  @doc """
  Claims `key` for this actor and request body.

  Returns `{:proceed, claim_id}` for the caller that must run the mutation and
  then call `complete/3`. Every other outcome is an answer in itself.
  """
  @spec claim(Actor.t(), String.t(), term()) :: claim()
  def claim(%Actor{} = actor, key, request_body), do: attempt(actor, key, request_body, 2)

  defp attempt(actor, key, request_body, attempts) when attempts > 0 do
    hash = request_hash(request_body)
    now = DateTime.utc_now()
    id = Ash.UUID.generate()

    entry = %{
      id: id,
      tenant_id: actor.tenant_id,
      role_assignment_id: actor.role_assignment.id,
      idempotency_key: key,
      request_hash: hash,
      state: "IN_PROGRESS",
      created_at: now,
      updated_at: now,
      expires_at: DateTime.add(now, @retention_hours, :hour)
    }

    case Dispatch.Repo.insert_all(Record, [entry],
           on_conflict: :nothing,
           conflict_target: [:tenant_id, :role_assignment_id, :idempotency_key]
         ) do
      {1, _inserted} -> {:proceed, id}
      {0, _conflict} -> resolve_existing(actor, key, hash, request_body, attempts - 1)
    end
  end

  # Only reachable if rows keep expiring between the insert and the read, which
  # cannot go on. Refusing beats looping.
  defp attempt(_actor, _key, _request_body, _exhausted), do: {:error, :in_progress}

  @doc """
  Stores the response for a claimed key.

  Called after the mutation succeeds. A mutation that fails leaves the claim
  `IN_PROGRESS` and is released by `abandon/1`, because storing a failure would
  make a transient error permanent for 24 hours.
  """
  @spec complete(Ash.UUID.t(), pos_integer(), map()) :: :ok
  def complete(claim_id, status, body) do
    from(r in Record, where: r.id == type(^claim_id, :binary_id))
    |> Dispatch.Repo.update_all(
      set: [
        state: "COMPLETED",
        response_status: status,
        response_body: body,
        updated_at: DateTime.utc_now()
      ]
    )

    :ok
  end

  @doc """
  Releases a claim whose mutation did not produce a stored response.

  The key becomes usable again. That is the right outcome for a rejected or
  failed request: the client's retry should be allowed to succeed, and Section
  24 stores *responses*, not attempts.
  """
  @spec abandon(Ash.UUID.t()) :: :ok
  def abandon(claim_id) do
    from(r in Record,
      where: r.id == type(^claim_id, :binary_id) and r.state == "IN_PROGRESS"
    )
    |> Dispatch.Repo.delete_all()

    :ok
  end

  @doc """
  Deletes records past their retention window.

  Reclaims space. It is not what enforces the bound — `claim/3` refuses to
  replay an expired row whether or not this has run — so a paused sweep costs
  storage rather than correctness.
  """
  @spec purge_expired(DateTime.t()) :: non_neg_integer()
  def purge_expired(now \\ DateTime.utc_now()) do
    {count, _} = from(r in Record, where: r.expires_at <= ^now) |> Dispatch.Repo.delete_all()
    count
  end

  @doc """
  The canonical hash of a request body.

  Keys are sorted recursively before encoding, so two bodies differing only in
  key order — which JSON does not consider significant — hash the same and
  replay, rather than being refused as a conflicting reuse.
  """
  @spec request_hash(term()) :: String.t()
  def request_hash(body) do
    body
    |> canonicalize()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonicalize(%{} = map) when not is_struct(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  defp resolve_existing(actor, key, hash, request_body, attempts) do
    query =
      from(r in Record,
        where:
          r.tenant_id == type(^actor.tenant_id, :binary_id) and
            r.role_assignment_id == type(^actor.role_assignment.id, :binary_id) and
            r.idempotency_key == ^key
      )

    case Dispatch.Repo.one(query) do
      nil -> attempt(actor, key, request_body, attempts)
      record -> resolve(record, actor, key, hash, request_body, attempts)
    end
  end

  # Expiry is decided here rather than left to `purge_expired/1`. Section 24
  # bounds storage at twenty-four hours, and a bound that only holds while a
  # sweep is running is not a bound: a stale row would otherwise keep replaying
  # a day-old response indefinitely if the job were paused or had never run.
  defp resolve(%Record{expires_at: expires_at} = record, actor, key, hash, body, attempts) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      live(record, hash)
    else
      # Past the window. The row is removed rather than ignored, because the
      # unique index would otherwise keep refusing the retry that replaces it.
      from(r in Record, where: r.id == type(^record.id, :binary_id))
      |> Dispatch.Repo.delete_all()

      attempt(actor, key, body, attempts)
    end
  end

  # Lost the insert race to a concurrent copy of the same request that has not
  # answered yet. A 409 is honest: the client should retry, and inventing a
  # response would mean guessing what the other request is about to store.
  defp live(%Record{request_hash: hash, state: "IN_PROGRESS"}, hash), do: {:error, :in_progress}

  defp live(%Record{request_hash: hash, response_status: status, response_body: body}, hash),
    do: {:replay, status, body}

  defp live(%Record{}, _different_hash), do: {:error, :key_reused}
end
