defmodule CoopSubstrate.ArtifactCustody.Quota do
  @moduledoc """
  Bytes a person has stored as evidence for one task
  (`CoopSubstrate.ArtifactCustody.store/5`): one process for the whole
  cluster (`BizKit.Cluster.Singleton`).

  Each digest occupies room once per key. Pending writes each hold a
  reservation; any successful write commits the digest. A failed or
  abandoned write releases only its own reservation, never a concurrent
  success. On worker death, verify the artifact on that worker's node before
  releasing room: a completed write stays charged even if its caller died
  before committing. An unreachable store conservatively keeps the charge.
  Room is refunded only when no write succeeded or remains pending.

  **Durable** (docs/architecture/2026-10-20-durable-quota.md): every
  reservation is recorded in `CoopSubstrate.Records` before `charge/4`
  replies, and how it settled before the settlement takes effect. On start,
  the process folds those records: committed digests count, and
  reservations still unsettled count too, as pending, so a restart or a
  move to another node neither forgets what was stored nor makes room for
  a second upload while the first may yet land. A restored reservation is
  settled by its writer's commit or refund. Recovery reattaches a monitor
  to the recorded writer; only confirmed writer death permits an absence
  check to release capacity. An unreachable or legacy unidentified writer
  keeps its reservation: a timeout is not evidence that a write stopped.
  """

  use GenServer

  alias CoopSubstrate.Records

  @table __MODULE__
  @server BizKit.Cluster.Singleton.name(__MODULE__)
  @stream "evidence-quota"

  @typedoc "A pending write's reservation: its recorded ID, and what it charged."
  @type reservation :: {String.t(), term(), binary(), non_neg_integer()}

  @doc "Run a local write with a reservation, committing only on success."
  def store(key, digest, bytes, limit, write) do
    with {:ok, reservation} <- charge(key, digest, bytes, limit) do
      result =
        try do
          write.()
        catch
          kind, reason ->
            refund(reservation)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      case result do
        {:ok, _} ->
          # A failed commit acknowledgement must leave the reservation in
          # place: the file already landed. Recovery can settle it later.
          :ok = commit(reservation)
          result

        error ->
          :ok = refund(reservation)
          error
      end
    end
  end

  @doc "Reserve room for a write, or return :held for a committed digest."
  @spec charge(term(), binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, reservation() | :held} | {:error, :quota_exceeded}
  def charge(key, digest, bytes, limit),
    do: GenServer.call(@server, {:charge, key, digest, bytes, limit})

  @doc "Commit a successful write's reservation. Repeated settlement is harmless."
  def commit(reservation), do: GenServer.call(@server, {:finish, reservation, true})

  @doc "Release only this failed write's reservation."
  def refund(reservation), do: GenServer.call(@server, {:finish, reservation, false})

  # -- server -------------------------------------------------------------------------

  # State: the reservations in flight, by ID: %{key, digest, bytes, node, monitor}.
  # A restored reservation starts without a monitor; recovery reattaches it.

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table])
    {committed, pending} = fold(recorded())

    for {key, digest, bytes} <- committed, do: count(key, digest, bytes, :committed)
    for {id, r} <- pending, do: count(r.key, r.digest, r.bytes, {:pending, id})

    state = Map.new(pending, fn {id, r} -> {id, Map.put(r, :monitor, nil)} end)
    if state != %{}, do: send(self(), :resolve_restored)
    {:ok, state}
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
        id = "r-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
        writer = Atom.to_string(node(pid))
        # Recorded before it is granted: no restart forgets room handed out.
        record({:reserved, id, key, digest, bytes, writer, :erlang.term_to_binary(pid)})
        count(key, digest, bytes, {:pending, id})

        reservation = %{
          key: key,
          digest: digest,
          bytes: bytes,
          node: writer,
          writer: :erlang.term_to_binary(pid),
          monitor: Process.monitor(pid)
        }

        {:reply, {:ok, {id, key, digest, bytes}}, Map.put(state, id, reservation)}
    end
  end

  def handle_call({:finish, :held, _success}, _from, state), do: {:reply, :ok, state}

  def handle_call({:finish, {id, key, digest, bytes}, success}, _from, state) do
    state =
      if Map.has_key?(state, id) do
        finish(state, id, success)
      else
        # Duplicate commit after a completed settlement. Recovery never
        # refunds a live writer, so this cannot resurrect expired capacity.
        if success, do: late_commit(key, digest, bytes)
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state, fn {_id, r} -> r.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {id, _r} when reason == :noconnection ->
        # A distribution disconnect is not writer death. It may still write
        # on the other side of the partition, even if its file is absent now.
        retry_recovery()
        {:noreply, put_in(state[id].monitor, nil)}

      {id, r} ->
        {:noreply, finish(state, id, landed?(r))}
    end
  end

  # Recovery never expires a live writer's right to land its file.
  def handle_info(:resolve_restored, state) do
    state =
      Enum.reduce(state, state, fn
        {id, %{monitor: nil, writer: writer} = r}, acc when is_binary(writer) ->
          case writer_status_on_node(r) do
            {:alive, pid} -> put_in(acc[id].monitor, Process.monitor(pid))
            :dead -> finish(acc, id, landed?(r))
            :unknown -> acc
          end

        _, acc ->
          acc
      end)

    if Enum.any?(state, fn {_, r} -> r.monitor == nil and r.writer != nil end),
      do: retry_recovery()

    {:noreply, state}
  end

  # Called on the writer's node. Encoding the PID as bytes keeps peer-node
  # atoms out of Records.Serializer's safe decode on a newly started node.
  # The PID includes the VM creation identity; a previous VM's PID is dead.
  @doc false
  def writer_status(encoded) do
    pid = :erlang.binary_to_term(encoded, [:safe])

    if is_pid(pid) and node(pid) == node() do
      if Process.alive?(pid), do: {:alive, pid}, else: :dead
    else
      :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  defp writer_status_on_node(r) do
    with {:ok, node} <- known_node(r.node) do
      case :rpc.call(node, __MODULE__, :writer_status, [r.writer], 2_000) do
        {:alive, pid} when is_pid(pid) -> {:alive, pid}
        :dead -> :dead
        _ -> :unknown
      end
    else
      :unknown -> :unknown
    end
  end

  # The caller may have died after persistence but before commit. Read on its
  # node: the singleton need not share its filesystem. Only proven absence
  # releases room; uncertainty must not let usable evidence escape the quota.
  defp landed?(r) do
    with {:ok, node} <- known_node(r.node) do
      :rpc.call(node, CoopSubstrate.Harness.Artifacts, :verify, [r.digest, r.bytes], 2_000) !=
        {:error, :not_found}
    else
      :unknown -> true
    end
  end

  defp known_node(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :unknown
  end

  defp finish(state, id, success) do
    {r, state} = Map.pop(state, id)
    if r.monitor, do: Process.demonitor(r.monitor, [:flush])
    # Recorded before it takes effect, so no restart undoes it.
    record({:settled, id, success})

    {used, charged} = :ets.lookup_element(@table, r.key, 2)
    entry = Map.fetch!(charged, r.digest)

    entry = %{
      entry
      | committed: entry.committed or success,
        pending: MapSet.delete(entry.pending, id)
    }

    {used, charged} =
      if not entry.committed and MapSet.size(entry.pending) == 0 do
        {used - entry.bytes, Map.delete(charged, r.digest)}
      else
        {used, Map.put(charged, r.digest, entry)}
      end

    :ets.insert(@table, {r.key, {used, charged}})
    state
  end

  defp late_commit(key, digest, bytes) do
    {_used, charged} = :ets.lookup_element(@table, key, 2, {0, %{}})

    unless match?(%{committed: true}, charged[digest]) do
      record({:committed, key, digest, bytes})
      count(key, digest, bytes, :committed)
    end
  end

  # Charge `digest` to `key`, once per key: committed, or pending under a reservation.
  defp count(key, digest, bytes, how) do
    {used, charged} = :ets.lookup_element(@table, key, 2, {0, %{}})
    blank = %{bytes: bytes, committed: false, pending: MapSet.new()}
    {used, entry} = if e = charged[digest], do: {used, e}, else: {used + bytes, blank}

    entry =
      case how do
        :committed -> %{entry | committed: true}
        {:pending, id} -> %{entry | pending: MapSet.put(entry.pending, id)}
      end

    :ets.insert(@table, {key, {used, Map.put(charged, digest, entry)}})
  end

  # -- records ------------------------------------------------------------------------

  # The committed digests, as {key, digest, bytes}, and the reservations not
  # yet settled, by ID.
  defp fold(records) do
    {committed, pending} =
      Enum.reduce(records, {[], %{}}, fn
        {:reserved, id, key, digest, bytes, node, writer}, {committed, pending} ->
          r = %{key: key, digest: digest, bytes: bytes, node: node, writer: writer}
          {committed, Map.put(pending, id, r)}

        {:reserved, id, key, digest, bytes, node}, {committed, pending} ->
          # Prior records lack writer identity. They cannot safely be expired
          # by inspecting an absent file; only explicit settlement frees them.
          r = %{key: key, digest: digest, bytes: bytes, node: node, writer: nil}
          {committed, Map.put(pending, id, r)}

        {:settled, id, success}, {committed, pending} ->
          {r, pending} = Map.pop(pending, id)

          {if(success and r, do: [{r.key, r.digest, r.bytes} | committed], else: committed),
           pending}

        {:committed, key, digest, bytes}, {committed, pending} ->
          {[{key, digest, bytes} | committed], pending}
      end)

    {Enum.reverse(committed), pending}
  end

  defp record(term) do
    :ok =
      Records.append_to_stream(@stream, :any_version, [
        %EventStore.EventData{event_type: "EvidenceQuota", data: term}
      ])
  end

  defp recorded do
    case Records.stream_forward(@stream) do
      {:error, :stream_not_found} -> []
      events -> Enum.map(events, & &1.data)
    end
  end

  defp retry_recovery do
    Process.send_after(
      self(),
      :resolve_restored,
      Application.get_env(:coop_substrate, :quota_recovery_retry_ms, 60_000)
    )
  end
end
