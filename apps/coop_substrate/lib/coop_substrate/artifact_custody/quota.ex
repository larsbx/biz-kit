defmodule CoopSubstrate.ArtifactCustody.Quota do
  @moduledoc """
  Bytes a person has stored as evidence for one task
  (`CoopSubstrate.ArtifactCustody.store/5`): one process for the whole
  cluster (`BizKit.Cluster.Singleton`), so the quota is the same on every
  node. If it moves, counting starts afresh.

  Each digest is charged once per key, so retrying an upload of the same
  bytes (storage is content-addressed) costs nothing more. A charge that
  reserves room says so (`:reserved`), and only that caller refunds it when
  its write fails; a concurrent upload of the same bytes finds it `:held`
  and leaves it alone.
  """

  use GenServer

  @table __MODULE__

  @server BizKit.Cluster.Singleton.name(__MODULE__)

  @doc """
  Charge `bytes` of `digest` to `key` if that keeps it within `limit`:
  `{:ok, :reserved}` if this call reserved the room, `{:ok, :held}` if the
  digest was already charged.
  """
  @spec charge(term(), binary(), non_neg_integer(), non_neg_integer()) ::
          {:ok, :reserved | :held} | {:error, :quota_exceeded}
  def charge(key, digest, bytes, limit),
    do: GenServer.call(@server, {:charge, key, digest, bytes, limit})

  @doc "Give back a reservation (`:reserved`) whose write failed."
  @spec refund(term(), binary()) :: :ok
  def refund(key, digest), do: GenServer.call(@server, {:refund, key, digest})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table])
    {:ok, nil}
  end

  # Per key: the running total and the bytes charged per digest.
  @impl true
  def handle_call({:charge, key, digest, bytes, limit}, _from, state) do
    {used, charged} = :ets.lookup_element(@table, key, 2, {0, %{}})

    cond do
      Map.has_key?(charged, digest) ->
        {:reply, {:ok, :held}, state}

      used + bytes <= limit ->
        :ets.insert(@table, {key, {used + bytes, Map.put(charged, digest, bytes)}})
        {:reply, {:ok, :reserved}, state}

      true ->
        {:reply, {:error, :quota_exceeded}, state}
    end
  end

  def handle_call({:refund, key, digest}, _from, state) do
    {used, charged} = :ets.lookup_element(@table, key, 2, {0, %{}})
    {bytes, rest} = Map.pop(charged, digest, 0)
    :ets.insert(@table, {key, {used - bytes, rest}})
    {:reply, :ok, state}
  end
end
