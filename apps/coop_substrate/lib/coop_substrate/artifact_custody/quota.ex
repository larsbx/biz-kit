defmodule CoopSubstrate.ArtifactCustody.Quota do
  @moduledoc """
  Bytes a person has stored as evidence for one task
  (`CoopSubstrate.ArtifactCustody.store/5`): one process for the whole
  cluster (`BizKit.Cluster.Singleton`), so the quota is the same on every
  node. If it moves, counting starts afresh.
  """

  use GenServer

  @table __MODULE__

  @server BizKit.Cluster.Singleton.name(__MODULE__)

  @doc "Charge `bytes` to `key` if that keeps it within `limit`."
  @spec charge(term(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, :quota_exceeded}
  def charge(key, bytes, limit), do: GenServer.call(@server, {:charge, key, bytes, limit})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table])
    {:ok, nil}
  end

  @impl true
  def handle_call({:charge, key, bytes, limit}, _from, state) do
    used = :ets.lookup_element(@table, key, 2, 0)

    if used + bytes <= limit do
      :ets.insert(@table, {key, used + bytes})
      {:reply, :ok, state}
    else
      {:reply, {:error, :quota_exceeded}, state}
    end
  end
end
