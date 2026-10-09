defmodule Keel.PrimitivesTest do
  use ExUnit.Case, async: true
  alias Keel.{Capability, Graph, Interval}

  describe "Interval [from, to)" do
    test "is half-open and nil-unbounded" do
      i = Interval.new(~D[2026-01-01], ~D[2026-02-01])
      assert Interval.contains?(i, ~D[2026-01-01])
      assert Interval.contains?(i, ~D[2026-01-31])
      refute Interval.contains?(i, ~D[2026-02-01])
      refute Interval.contains?(i, ~D[2025-12-31])
      assert Interval.contains?(Interval.always(), ~D[1900-01-01])
    end

    test "well-formedness rejects empty intervals" do
      assert Interval.well_formed?(Interval.new(~D[2026-01-01]))
      refute Interval.well_formed?(Interval.new(~D[2026-01-01], ~D[2026-01-01]))
    end
  end

  describe "Capability preorder" do
    test "wildcard, bare and limited capabilities" do
      assert Capability.covers?(:*, {:spend, 10})
      assert Capability.covers?(:spend, {:spend, 10})
      assert Capability.covers?({:spend, 10}, {:spend, 5})
      refute Capability.covers?({:spend, 5}, {:spend, 10})
      refute Capability.covers?({:spend, 5}, :spend)
      refute Capability.covers?(:hire, :fire)
    end

    test "is transitive on a chain" do
      assert Capability.covers?(:spend, {:spend, 10}) and
               Capability.covers?({:spend, 10}, {:spend, 3})

      assert Capability.covers?(:spend, {:spend, 3})
    end
  end

  describe "Graph" do
    test "finds a closed cycle path or nil" do
      assert Graph.cycle([{:a, :b}, {:b, :c}]) == nil
      assert Graph.cycle([{:a, :b}, {:b, :c}, {:c, :b}]) == [:b, :c, :b]
      assert Graph.cycle([{:a, :a}]) == [:a, :a]
    end

    test "reaches? follows edges until the predicate holds" do
      g = [{:a, :b}, {:b, :c}, {:c, :a}]
      assert Graph.reaches?(g, :a, &(&1 == :c))
      refute Graph.reaches?(g, :a, &(&1 == :z))
    end
  end
end
