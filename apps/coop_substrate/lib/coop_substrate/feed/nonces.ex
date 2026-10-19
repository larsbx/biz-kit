defmodule CoopSubstrate.Feed.Nonces do
  @moduledoc """
  Spent read-request nonces, so a signed request is accepted once.

  A nonce is kept until its request falls out of the freshness window, after
  which `Access.authorize/4` refuses the request as stale anyway. The table
  lives in one process for the whole cluster (`BizKit.Cluster.Singleton`),
  so a nonce spent on one node is spent on all. If it moves, it forgets,
  which is safe for the same reason as a restart: within the window a
  request could be replayed once more, and after it, it is stale.
  """

  use GenServer

  alias CoopSubstrate.Feed.Access

  @table __MODULE__

  @server BizKit.Cluster.Singleton.name(__MODULE__)

  @doc "Spend `nonce` for a request made at `timestamp_ms`."
  @spec claim(String.t(), integer()) :: :ok | {:error, :replayed}
  def claim(nonce, timestamp_ms), do: GenServer.call(@server, {:claim, nonce, timestamp_ms})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_call({:claim, nonce, timestamp_ms}, _from, state) do
    reply =
      if :ets.insert_new(@table, {nonce, timestamp_ms + Access.window_ms()}),
        do: :ok,
        else: {:error, :replayed}

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, Access.window_ms())
end
