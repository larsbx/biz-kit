defmodule Dispatch.Idempotency do
  @moduledoc """
  The `Idempotency-Key` ledger of Section 24.

  > Every mutation accepts `Idempotency-Key`. The server stores the key, actor,
  > request hash, response status, and response body for 24 hours. Reuse with a
  > different request hash returns `409 IDEMPOTENCY_KEY_REUSED`.

  ## The mutation and its record commit together

  `execute/4` runs the claim, the mutation, and the stored response inside one
  transaction. That is the whole design, and it is what makes the guarantee
  real rather than nearly real.

  The tempting shape is a claim, then the mutation, then a separate write
  recording the response. It has a window: a process that dies between the
  mutation and the record leaves a key claimed with no response behind it.
  Nothing can then tell — from the row, later — whether the mutation ran. A
  lease on such a claim only chooses which way to be wrong: refuse the retry
  and the key is dead until it expires, or let it through and the mutation runs
  twice. Neither is idempotency; they are two ways of not having it.

  In one transaction the question does not arise. Either both are durable or
  neither is, and a process that dies takes its claim down with the work.

  ## Why a reservation rather than a lookup

  Look-then-write races exactly where it matters: two copies of one request
  arriving together both find nothing and both run. A handset retrying over a
  flaky link is the *normal* case (Section 14's offline outbox), so this is not
  hypothetical.

  The key is therefore claimed first, by `INSERT ... ON CONFLICT DO NOTHING`
  against the unique index. A concurrent copy blocks on that uncommitted row
  rather than racing past it, and when the first transaction ends it sees the
  outcome: the stored response if the first committed, or a free key if it
  rolled back. The wait is bounded by `lock_timeout`, so a request cannot be
  held behind a pathologically slow one — it is answered as in-progress
  instead.

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

  # How long a request waits for a concurrent copy of itself to finish before
  # being answered as in-progress. Generous next to any request this service
  # should serve, short enough that one pathological request cannot pile up
  # every retry behind it.
  @lock_timeout "3s"

  @typedoc "What a mutation reports: an HTTP status and the body to store."
  @type outcome :: {:ok, pos_integer(), map()} | {:error, term()}

  @typedoc "An answer to a request, whether it ran the mutation or not."
  @type result :: outcome() | {:error, :key_reused} | {:error, :in_progress}

  @doc """
  Runs `fun` under `key`, storing its response for replay.

  `fun` returns `{:ok, status, body}` for a response worth storing, or
  `{:error, reason}` for a rejection. A rejection rolls the transaction back,
  which releases the key *and* undoes whatever the mutation had written — so a
  corrected retry may reuse the key, and a failed attempt leaves nothing
  behind. Section 24 stores responses, not attempts.

  A `nil` key runs `fun` directly. Section 24 says every mutation *accepts*
  `Idempotency-Key`; the ledger is how the ones that send it are honoured, not
  a way to require it.
  """
  @spec execute(Actor.t(), String.t() | nil, term(), (-> outcome())) :: result()
  def execute(actor, key, request_body, fun)

  def execute(%Actor{}, nil, _request_body, fun), do: fun.()

  def execute(%Actor{} = actor, key, request_body, fun) when is_binary(key) do
    try do
      Dispatch.Repo.transaction(fn ->
        with {:proceed, claim_id} <- claim(actor, key, request_body),
             {:ok, status, body} = ok <- fun.() do
          complete(claim_id, status, body)
          ok
        else
          # The claim and anything the mutation wrote go back together. Storing a
          # failure would make a transient client error permanent for a day.
          {:error, _reason} = error -> Dispatch.Repo.rollback(error)
          {:replay, status, body} -> {:ok, status, body}
        end
      end)
      |> unwrap()
    rescue
      # A lock timeout aborts PostgreSQL's transaction. Translate it only after
      # Repo.transaction/1 has rolled that transaction back; rescuing inside
      # claim/4 would leave every later statement in an aborted transaction.
      error in Postgrex.Error ->
        if lock_timeout?(error),
          do: {:error, :in_progress},
          else: reraise(error, __STACKTRACE__)
    end
  end

  # `Repo.transaction/1` wraps the committed value and hands back a rollback
  # value unchanged; both are already the shape a caller expects.
  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, result}), do: result

  @doc """
  Deletes records past their retention window.

  Reclaims space. It is not what enforces the bound — `execute/4` refuses to
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

  defp claim(actor, key, request_body, attempts \\ 2)

  defp claim(actor, key, request_body, attempts) when attempts > 0 do
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

    # Bounded, so a request blocked behind a concurrent copy of itself is
    # answered rather than held. The setting is local to this transaction.
    %Postgrex.Result{} = Dispatch.Repo.query!("SET LOCAL lock_timeout = '#{@lock_timeout}'")

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
  defp claim(_actor, _key, _request_body, _exhausted), do: {:error, :in_progress}

  defp lock_timeout?(%Postgrex.Error{postgres: %{code: code}}), do: code == :lock_not_available
  defp lock_timeout?(_error), do: false

  defp complete(claim_id, status, body) do
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

  defp resolve_existing(actor, key, hash, request_body, attempts) do
    query =
      from(r in Record,
        where:
          r.tenant_id == type(^actor.tenant_id, :binary_id) and
            r.role_assignment_id == type(^actor.role_assignment.id, :binary_id) and
            r.idempotency_key == ^key
      )

    case Dispatch.Repo.one(query) do
      nil -> claim(actor, key, request_body, attempts)
      record -> resolve(record, actor, key, request_body, hash, attempts)
    end
  end

  # Expiry is decided here rather than left to `purge_expired/1`. Section 24
  # bounds storage at twenty-four hours, and a bound that only holds while a
  # sweep is running is not a bound: a stale row would otherwise keep replaying
  # a day-old response indefinitely if the job were paused or had never run.
  defp resolve(%Record{expires_at: expires_at} = record, actor, key, body, hash, attempts) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
      live(record, hash)
    else
      # Past the window. The row is removed rather than ignored, because the
      # unique index would otherwise keep refusing the retry that replaces it.
      from(r in Record, where: r.id == type(^record.id, :binary_id))
      |> Dispatch.Repo.delete_all()

      claim(actor, key, body, attempts)
    end
  end

  # A committed row always carries its response, because `execute/4` writes both
  # in one transaction. An `IN_PROGRESS` row visible to another transaction is
  # therefore not a crashed request — it is a caller that took a claim outside
  # `execute/4`, and answering it as in-progress is the conservative reading.
  defp live(%Record{request_hash: hash, state: "IN_PROGRESS"}, hash), do: {:error, :in_progress}

  defp live(%Record{request_hash: hash, response_status: status, response_body: body}, hash),
    do: {:replay, status, body}

  defp live(%Record{}, _different_hash), do: {:error, :key_reused}
end
