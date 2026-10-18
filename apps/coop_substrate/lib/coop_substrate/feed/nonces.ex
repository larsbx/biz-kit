defmodule CoopSubstrate.Feed.Nonces do
  @moduledoc """
  Spent read-request nonces, so a signed request is accepted once.

  A nonce is kept until its request falls out of the freshness window, after
  which `Access.authorize/4` refuses the request as stale anyway. The table
  lives in this node's memory: a restart forgets it, which is safe for the
  same reason, and several nodes serving the feed would need a shared store.
  """

  use GenServer

  alias CoopSubstrate.Feed.Access

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Spend `nonce` for a request made at `timestamp_ms`."
  @spec claim(String.t(), integer()) :: :ok | {:error, :replayed}
  def claim(nonce, timestamp_ms) do
    if :ets.insert_new(@table, {nonce, timestamp_ms + Access.window_ms()}),
      do: :ok,
      else: {:error, :replayed}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    schedule()
    {:ok, nil}
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
