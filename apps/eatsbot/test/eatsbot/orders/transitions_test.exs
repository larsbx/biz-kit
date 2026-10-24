defmodule EatsbotCore.Orders.TransitionsTest do
  @moduledoc """
  The order lifecycle is finite (8 states × 3 fulfillments), so every property
  below is checked exhaustively: each test is a proof by enumeration, not a sample.
  """
  use ExUnit.Case, async: true

  alias EatsbotCore.Orders.Transitions, as: T

  @states ~w(placed accepted preparing ready dispatched completed cancelled failed)a
  @fulfillments ~w(delivery pickup dine_in)a
  @terminal ~w(completed cancelled failed)a

  # The specification, written independently of the implementation:
  # δ from the roadmap spec, with its fulfillment guards.
  @spec_delta MapSet.new(
                for f <- @fulfillments,
                    {from, to, guard} <- [
                      {:placed, :accepted, :any},
                      {:accepted, :preparing, :any},
                      {:preparing, :ready, :any},
                      {:ready, :dispatched, :delivery},
                      {:ready, :completed, :not_delivery},
                      {:dispatched, :completed, :delivery},
                      {:dispatched, :failed, :delivery},
                      {:placed, :cancelled, :any},
                      {:accepted, :cancelled, :any},
                      {:preparing, :cancelled, :any},
                      {:ready, :cancelled, :any}
                    ],
                    guard == :any or (guard == :delivery and f == :delivery) or
                      (guard == :not_delivery and f != :delivery),
                    do: {f, from, to}
              )

  test "state and fulfillment sets match the spec" do
    assert MapSet.new(T.states()) == MapSet.new(@states)
    assert MapSet.new(T.fulfillments()) == MapSet.new(@fulfillments)
    assert MapSet.new(T.terminal_states()) == MapSet.new(@terminal)
    assert T.initial_state() == :placed
  end

  test "legal?/3 equals δ on all 192 (fulfillment, from, to) triples" do
    for f <- @fulfillments, from <- @states, to <- @states do
      assert T.legal?(f, from, to) == MapSet.member?(@spec_delta, {f, from, to}),
             "#{f}: #{from} -> #{to}"
    end
  end

  test "next_states/2 is exactly the image of δ" do
    for f <- @fulfillments, from <- @states do
      expected = for {^f, ^from, to} <- @spec_delta, into: MapSet.new(), do: to
      assert MapSet.new(T.next_states(f, from)) == expected
    end
  end

  test "terminal states are absorbing" do
    for f <- @fulfillments, s <- @terminal, do: assert(T.next_states(f, s) == [], "#{f}/#{s}")
  end

  test "every reachable non-terminal state has a successor" do
    # Unreachable states may have none: a pickup order never reaches :dispatched.
    for f <- @fulfillments, s <- reachable(f, [:placed]), s not in @terminal do
      assert T.next_states(f, s) != [], "#{f}/#{s} is stuck"
    end
  end

  test "every state reachable for a fulfillment can reach a terminal state (no dead ends)" do
    for f <- @fulfillments, s <- reachable(f, [:placed]) do
      assert Enum.any?(reachable(f, [s]), &(&1 in @terminal)), "#{f}/#{s} cannot terminate"
    end
  end

  test "the graph is acyclic, so every path terminates" do
    for f <- @fulfillments, s <- @states do
      refute s in reachable(f, T.next_states(f, s)), "cycle through #{f}/#{s}"
    end
  end

  test "dispatched and failed are reachable only for delivery" do
    for f <- @fulfillments do
      reached = reachable(f, [:placed])
      assert :dispatched in reached == (f == :delivery)
      assert :failed in reached == (f == :delivery)
    end
  end

  describe "replay/2 (I₆: the history determines the state)" do
    test "a legal history replays to its last state" do
      history = [{:placed, :accepted}, {:accepted, :preparing}, {:preparing, :ready}]
      assert T.replay(:pickup, history) == {:ok, :ready}
      assert T.replay(:pickup, []) == {:ok, :placed}
    end

    test "every path from placed replays to its endpoint" do
      for f <- @fulfillments, path <- paths(f, :placed) do
        steps = Enum.zip(path, tl(path))
        assert T.replay(f, steps) == {:ok, List.last(path)}
      end
    end

    test "a history with a gap or an illegal step is rejected at that step" do
      assert T.replay(:pickup, [{:placed, :accepted}, {:preparing, :ready}]) ==
               {:error, {:discontinuous, 1}}

      assert T.replay(:pickup, [{:placed, :accepted}, {:accepted, :ready}]) ==
               {:error, {:illegal, 1, :accepted, :ready}}

      assert T.replay(:pickup, [
               {:placed, :accepted},
               {:accepted, :preparing},
               {:preparing, :ready},
               {:ready, :dispatched}
             ]) ==
               {:error, {:illegal, 3, :ready, :dispatched}}
    end
  end

  defp reachable(f, frontier, seen \\ MapSet.new())
  defp reachable(_f, [], seen), do: MapSet.to_list(seen)

  defp reachable(f, [s | rest], seen) do
    if MapSet.member?(seen, s),
      do: reachable(f, rest, seen),
      else: reachable(f, T.next_states(f, s) ++ rest, MapSet.put(seen, s))
  end

  # All maximal paths; finite because the graph is acyclic (proven above).
  defp paths(f, s) do
    case T.next_states(f, s) do
      [] -> [[s]]
      next -> for n <- next, p <- paths(f, n), do: [s | p]
    end
  end
end
