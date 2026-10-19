defmodule BizKit.Cluster.SingletonTest do
  @moduledoc """
  One process per cluster (docs/architecture/2026-10-19-cluster.md), on real
  peer nodes: one runs it and every node reaches it; when its node stops,
  another takes over; after a partition heals, one remains.
  """
  use ExUnit.Case, async: false

  alias BizKit.Cluster.Peers

  setup_all do
    Peers.distribute!()
  end

  defp eventually(fun, tries \\ 200) do
    case fun.() do
      true ->
        :ok

      _ when tries > 0 ->
        Process.sleep(20)
        eventually(fun, tries - 1)

      other ->
        flunk("still #{inspect(other)}")
    end
  end

  defp everywhere(nodes), do: Enum.map(nodes, &:erpc.call(&1, Peers, :where, []))

  test "one runs it, every node reaches the same one" do
    nodes = for _ <- 1..3, do: elem(Peers.start!(), 1)
    Peers.mesh!(nodes)
    Enum.each(nodes, &Peers.keep!/1)

    [where | _] = answers = everywhere(nodes)
    assert Enum.uniq(answers) == [where]
    assert where in nodes
    assert Peers.where() == where
  end

  test "when its node stops, another takes over" do
    peers = for _ <- 1..3, do: Peers.start!()
    Peers.mesh!(for {_, node} <- peers, do: node)
    Enum.each(peers, fn {_, node} -> Peers.keep!(node) end)

    first = Peers.where()
    {peer, ^first} = List.keyfind(peers, first, 1)
    :peer.stop(peer)

    eventually(fn ->
      try do
        Peers.where() not in [first]
      catch
        :exit, _ -> false
      end
    end)

    survivors = for {_, node} <- peers, node != first, do: node
    assert Peers.where() in survivors
    assert Enum.uniq(everywhere(survivors)) == [Peers.where()]
  end

  # Driven over the peers' stdio control channel: cutting a link makes
  # :global isolate the node from everyone, this one included.
  test "after a partition heals, one remains" do
    [{pa, a}, {pb, b}] = for _ <- 1..2, do: Peers.start!()
    Peers.mesh!([a, b])
    Enum.each([a, b], &Peers.keep!/1)
    # Nil while a side is between instances.
    on = fn peer ->
      try do
        :peer.call(peer, Peers, :where, [])
      catch
        :exit, _ -> nil
      end
    end

    eventually(fn -> on.(pa) != nil and on.(pa) == on.(pb) end)

    true = :peer.call(pa, :erlang, :disconnect_node, [b])
    eventually(fn -> {on.(pa), on.(pb)} == {a, b} end)

    true = :peer.call(pa, Node, :connect, [b])
    :ok = :peer.call(pa, :global, :sync, [])
    eventually(fn -> on.(pa) != nil and on.(pa) == on.(pb) end)

    # The survivor is on the lower-named node; the other keeper watches it.
    assert on.(pa) == min(a, b)

    names = fn peer -> :peer.call(peer, :global, :registered_names, []) end
    assert Enum.count(names.(pa), &(&1 == Peers.Where)) == 1
  end
end
