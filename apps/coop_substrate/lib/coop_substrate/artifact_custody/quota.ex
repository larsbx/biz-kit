defmodule CoopSubstrate.ArtifactCustody.Quota do
  @moduledoc """
  Bytes a person has stored as evidence for one task
  (`CoopSubstrate.ArtifactCustody.store/5`): one process for the whole
  cluster (`BizKit.Cluster.Singleton`), so the quota is the same on every
  node. If it moves, counting starts afresh.

  Each digest is charged once per key, so retrying an upload of the same
  bytes (storage is content-addressed) costs nothing more, and a charge is
  refunded when the write it reserved for fails.
  """

  use GenServer

  @table __MODULE__

  @server BizKit.Cluster.Singleton.name(__MODULE__)

  @doc "Charge `bytes` of `digest` to `key` if that keeps it within `limit`; once per digest."
  @spec charge(term(), binary(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :quota_exceeded}
  def charge(key, digest, bytes, limit),
    do: GenServer.call(@server, {:charge, key, digest, bytes, limit})

  @doc "Give back a charge whose write failed."
  @spec refund(term(), binary()) :: :ok
  def refund(key, digest), do: GenServer.call(@server, {:refund, key, digest})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table])
    {:ok, nil}
  end

  @impl true
  def handle_call({:charge, key, digest, bytes, limit}, _from, state) do
    charged = :ets.lookup_element(@table, key, 2, %{})
    used = charged |> Map.values() |> Enum.sum()

    cond do
      Map.has_key?(charged, digest) ->
        {:reply, :ok, state}

      used + bytes <= limit ->
        :ets.insert(@table, {key, Map.put(charged, digest, bytes)})
        {:reply, :ok, state}

      true ->
        {:reply, {:error, :quota_exceeded}, state}
    end
  end

  def handle_call({:refund, key, digest}, _from, state) do
    :ets.insert(@table, {key, Map.delete(:ets.lookup_element(@table, key, 2, %{}), digest)})
    {:reply, :ok, state}
  end
end
