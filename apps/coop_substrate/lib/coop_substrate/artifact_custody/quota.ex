defmodule CoopSubstrate.ArtifactCustody.Quota do
  @moduledoc """
  Bytes a person has stored as evidence for one task
  (`CoopSubstrate.ArtifactCustody.store/5`): one process for the whole
  cluster (`BizKit.Cluster.Singleton`).

  **Durable** (docs/architecture/2026-10-20-durable-quota.md): every digest
  committed to a key is recorded in `CoopSubstrate.Records` before the
  commit returns, and the process rebuilds its charges from those records
  when it starts, so moving to another node or restarting the cluster
  forgets nothing stored. A reservation names what it charged, so a write
  still in flight when the process restarts is recorded when it succeeds.
  Only reservations in flight are in memory: a restart refunds them, which
  only makes room for writes that did not land.

  Each digest occupies room once per key. Pending writes each hold a
  monitored reservation; any successful write commits the digest. A failed
  or abandoned write releases only its own reservation, never a concurrent
  success. On worker death, verify the artifact on that worker's node before
  releasing room: a completed write stays charged even if its caller died
  before committing. An unreachable store conservatively keeps the charge.
  Room is refunded only when no write succeeded or remains pending.
  """

  use GenServer

  alias CoopSubstrate.Records

  @table __MODULE__
  @server BizKit.Cluster.Singleton.name(__MODULE__)
  @stream "evidence-quota"

  @doc "Run a local write with a reservation, committing only on success."
  def store(key, digest, bytes, limit, write) do
    with {:ok, reservation} <- charge(key, digest, bytes, limit) do
      try do
        case write.() do
          {:ok, _} = result ->
            :ok = commit(reservation)
            result

          error ->
            error
        end
      after
        # Also covers exceptions and exits. A committed token is already
        # settled, so this cannot refund a successful write.
        refund(reservation)
      end
    end
  end

  @typedoc "A pending write's reservation: its monitor, and what it charged."
  @type reservation :: {reference(), term(), binary(), non_neg_integer()}

  @doc "Reserve room for a write, or return :held for a committed digest."
  @spec charge(term(), binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, reservation() | :held} | {:error, :quota_exceeded}
  def charge(key, digest, bytes, limit),
    do: GenServer.call(@server, {:charge, key, digest, bytes, limit})

  @doc "Commit a successful write's reservation. Repeated settlement is harmless."
  def commit(reservation), do: GenServer.call(@server, {:finish, reservation, true})

  @doc "Release only this failed write's reservation."
  def refund(reservation), do: GenServer.call(@server, {:finish, reservation, false})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table])

    # What every earlier incarnation committed, wherever it ran.
    for {key, digest, bytes} <- recorded(), do: settle(key, digest, bytes)

    {:ok, %{}}
  end

  @impl true
  def handle_call({:charge, key, digest, bytes, limit}, {pid, _}, state) do
    {used, charged} = :ets.lookup_element(@table, key, 2, {0, %{}})
    entry = Map.get(charged, digest)

    cond do
      entry != nil and entry.committed ->
        {:reply, {:ok, :held}, state}

      entry == nil and used + bytes > limit ->
        {:reply, {:error, :quota_exceeded}, state}

      true ->
        token = Process.monitor(pid)
        used = if entry == nil, do: used + bytes, else: used
        entry = entry || %{bytes: bytes, committed: false, pending: MapSet.new()}
        entry = %{entry | pending: MapSet.put(entry.pending, token)}
        :ets.insert(@table, {key, {used, Map.put(charged, digest, entry)}})

        {:reply, {:ok, {token, key, digest, bytes}},
         Map.put(state, token, {key, digest, node(pid), bytes})}
    end
  end

  def handle_call({:finish, :held, _success}, _from, state), do: {:reply, :ok, state}

  def handle_call({:finish, {token, key, digest, bytes}, success}, _from, state) do
    # A reservation this incarnation never made (it restarted mid-write):
    # a success is still a stored digest, recorded like any other.
    state =
      if not Map.has_key?(state, token) and success,
        do: tap(state, fn _ -> commit_new(key, digest, bytes) end),
        else: finish(state, token, success)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, token, :process, _pid, _reason}, state) do
    success =
      case Map.get(state, token) do
        nil ->
          false

        {_key, digest, storage_node, bytes} ->
          # The caller may have died after persistence but before commit.
          # Read on its node: the singleton need not share its filesystem.
          # Only proven absence releases room; uncertainty must not permit
          # usable evidence to escape the quota.
          :rpc.call(
            storage_node,
            CoopSubstrate.Harness.Artifacts,
            :verify,
            [digest, bytes],
            2_000
          ) !=
            {:error, :not_found}
      end

    {:noreply, finish(state, token, success)}
  end

  defp finish(state, token, success) do
    case Map.pop(state, token) do
      {nil, state} ->
        state

      {{key, digest, _storage_node, _bytes}, state} ->
        Process.demonitor(token, [:flush])
        {used, charged} = :ets.lookup_element(@table, key, 2)
        entry = Map.fetch!(charged, digest)

        # Recorded before it counts as committed, so no restart forgets it.
        if success and not entry.committed, do: record(key, digest, entry.bytes)

        entry = %{
          entry
          | committed: entry.committed or success,
            pending: MapSet.delete(entry.pending, token)
        }

        {used, charged} =
          if not entry.committed and MapSet.size(entry.pending) == 0 do
            {used - entry.bytes, Map.delete(charged, digest)}
          else
            {used, Map.put(charged, digest, entry)}
          end

        :ets.insert(@table, {key, {used, charged}})
        state
    end
  end

  # A digest committed to a key: recorded once, then charged.
  defp commit_new(key, digest, bytes) do
    {_used, charged} = :ets.lookup_element(@table, key, 2, {0, %{}})

    unless match?(%{committed: true}, charged[digest]) do
      record(key, digest, bytes)
      settle(key, digest, bytes)
    end
  end

  # Charge a recorded digest as committed, once per key.
  defp settle(key, digest, bytes) do
    {used, charged} = :ets.lookup_element(@table, key, 2, {0, %{}})

    {used, entry} =
      case charged[digest] do
        nil -> {used + bytes, %{bytes: bytes, committed: true, pending: MapSet.new()}}
        entry -> {used, %{entry | committed: true}}
      end

    :ets.insert(@table, {key, {used, Map.put(charged, digest, entry)}})
  end

  defp record(key, digest, bytes) do
    :ok =
      Records.append_to_stream(@stream, :any_version, [
        %EventStore.EventData{event_type: "EvidenceCommitted", data: {key, digest, bytes}}
      ])
  end

  defp recorded do
    case Records.stream_forward(@stream) do
      {:error, :stream_not_found} -> []
      events -> Enum.map(events, & &1.data)
    end
  end
end
