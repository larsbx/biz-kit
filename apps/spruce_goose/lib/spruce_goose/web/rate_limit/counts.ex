defmodule SpruceGoose.Web.RateLimit.Counts do
  @moduledoc """
  The counts `SpruceGoose.Web.RateLimit` keeps, per bucket, client and
  window: one process for the whole cluster (`BizKit.Cluster.Singleton`),
  so a client's limit is the same however its requests are spread over the
  nodes. If it moves, counting starts afresh.
  """

  use GenServer

  @table __MODULE__
  @sweep_ms 60_000

  @server BizKit.Cluster.Singleton.name(__MODULE__)

  @doc "Count one request for `key` in the window ending at `ends`; the count so far."
  @spec hit(term(), integer()) :: pos_integer()
  def hit(key, ends), do: GenServer.call(@server, {:hit, key, ends})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table])
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_call({:hit, key, ends}, _from, state),
    do: {:reply, :ets.update_counter(@table, {key, ends}, {2, 1}, {{key, ends}, 0}), state}

  # Windows that have ended no longer count.
  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", now}], [true]}])
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @sweep_ms)
end
