defmodule SpruceGoose.Web.RateLimit.Counts do
  @moduledoc "The counts `SpruceGoose.Web.RateLimit` keeps, per bucket, client and window."

  use GenServer

  @table __MODULE__
  @sweep_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Count one request for `key` in the window ending at `ends`; the count so far."
  @spec hit(term(), integer()) :: pos_integer()
  def hit(key, ends), do: :ets.update_counter(@table, {key, ends}, {2, 1}, {{key, ends}, 0})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    schedule()
    {:ok, nil}
  end

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
