defmodule BizKit.Cluster do
  @moduledoc """
  Several biz-kit nodes as one service (docs/architecture/2026-10-19-cluster.md).

  The nodes form a distributed Erlang cluster: each connects to the others
  listed in `config :biz_kit_cluster, nodes: [...]` (at runtime
  `BIZKIT_CLUSTER_NODES`), and keeps trying, so a node that restarts or
  joins later is found. State that must be one for the whole service (the
  ledger's appender, sessions, held commands) lives in one process per
  cluster, kept by `BizKit.Cluster.Singleton`.

  A single node with no peers configured is a cluster of one.
  """

  use GenServer

  @interval_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The peers this node keeps connected to."
  @spec peers() :: [node()]
  def peers, do: Application.get_env(:biz_kit_cluster, :nodes, []) -- [node()]

  @impl true
  def init(_opts) do
    send(self(), :connect)
    {:ok, nil}
  end

  @impl true
  def handle_info(:connect, state) do
    if Node.alive?(), do: for(peer <- peers() -- Node.list(), do: Node.connect(peer))
    Process.send_after(self(), :connect, @interval_ms)
    {:noreply, state}
  end
end
