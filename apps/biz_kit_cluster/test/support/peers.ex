defmodule BizKit.Cluster.Peers do
  @moduledoc """
  Peer nodes for cluster tests: this node made distributed, peers started
  with its code and cookie, and a keeper of `Where` on any of them.
  """

  alias BizKit.Cluster.Singleton

  defmodule Where do
    @moduledoc "A singleton that says which node it runs on."
    use GenServer
    def init(_), do: {:ok, node()}
    def handle_call(:where, _from, node), do: {:reply, node, node}
  end

  def distribute! do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        :net_kernel.start([:"cluster_test_#{System.unique_integer([:positive])}@127.0.0.1"])
    end

    :ok
  end

  @doc "A connected peer node; stopped when the test ends."
  def start! do
    {:ok, peer, node} =
      :peer.start_link(%{
        name: :peer.random_name(),
        host: ~c"127.0.0.1",
        longnames: true,
        # Control over stdio, so cutting distribution leaves the peer reachable.
        connection: :standard_io,
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])
    true = Node.connect(node)
    ExUnit.Callbacks.on_exit(fn -> try do: :peer.stop(peer), catch: (_, _ -> :ok) end)
    {peer, node}
  end

  @doc "Connect every node to every other, as `BizKit.Cluster` does from its config."
  def mesh!(nodes) do
    for a <- nodes, b <- nodes, a < b, do: true = :erpc.call(a, Node, :connect, [b])
    Enum.each([node() | nodes], &(:ok = :erpc.call(&1, :global, :sync, [])))
  end

  @doc "A keeper of `Where` on `node`, under a supervisor that outlives the call."
  def keep!(node) do
    :ok = :erpc.call(node, __MODULE__, :start_keeper, [])
  end

  def start_keeper do
    parent = self()

    spawn(fn ->
      {:ok, _} = Supervisor.start_link([{Singleton, Where}], strategy: :one_for_one)
      send(parent, :kept)
      Process.sleep(:infinity)
    end)

    receive do
      :kept -> :ok
    end
  end

  def where, do: GenServer.call(Singleton.name(Where), :where)

  @doc """
  On `node`, a process in `:pg` group `group` of `scope` (started there if
  need be) that forwards each message it gets to `to`; returns once joined.
  """
  def relay!(node, scope, group, to),
    do: :ok = :erpc.call(node, __MODULE__, :relay, [scope, group, to])

  def relay(scope, group, to) do
    parent = self()

    spawn(fn ->
      _ = :pg.start(scope)
      :ok = :pg.join(scope, group, self())
      send(parent, :joined)
      forward(to)
    end)

    receive do
      :joined -> :ok
    end
  end

  defp forward(to) do
    receive do
      message -> send(to, {:relayed, node(), message})
    end

    forward(to)
  end
end
