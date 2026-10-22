defmodule Keel.ConformanceTest do
  use ExUnit.Case, async: true
  alias Keel.{Forms, Interval, Invariants, Line, Org, Ownership, Party, Role, Seat, Stake, Unit}

  @t ~D[2026-06-01]
  @later ~D[2026-09-01]

  test "constructible invalid primitives survive new, put_all and put for diagnosis" do
    bad = [
      %Party{id: :bad, kind: :robot},
      %Seat{party: :ghost, role: :missing},
      %Seat{party: :ann, role: :r, during: Interval.new(@t, @t)},
      %Stake{holder: :ann, in: :co, units: 0}
    ]

    base = [Forms.entity(:co), %Party{id: :ann, kind: :person}, %Role{id: :r, unit: {:co, :hq}}]
    org = Org.new([base, [bad]])
    assert org == Org.put_all(Org.new(base), bad)
    assert org == Enum.reduce(bad, Org.new(base), &Org.put(&2, &1))
    refute Invariants.valid?(org)

    assert MapSet.new(Enum.map(Invariants.check(org), &elem(&1, 0))) ==
             MapSet.new([:references, :kinds, :intervals, :stakes])

    assert_raise ArgumentError, fn -> Org.put(org, %Party{id: :ann}) end
    assert_raise FunctionClauseError, fn -> Org.put(org, :unsupported) end
  end

  test "cooperative keyword options preserve defaults and capital separately from votes" do
    for form <- [:cooperative, :worker_cooperative] do
      default = apply(Forms, form, [:co, [:ann, :bob], :ann])
      assert default == apply(Forms, form, [:co, [:ann, :bob], :ann, []])
      assert default == apply(Forms, form, [:co, [:ann, :bob], :ann, [capital: %{}]])
      funded = apply(Forms, form, [:co, [:ann, :bob], :ann, [capital: %{ann: 10, bob: 3}]])
      org = Org.new([%Party{id: :ann, kind: :person}, %Party{id: :bob, kind: :person}, funded])
      assert Invariants.check(org) == []
      assert Org.members(org, {:co, :assembly}, @t) == %{ann: 1, bob: 1}
      assert Org.holding(org, :ann, :co, :capital, @t) == 10
      assert Org.holding(org, :bob, :co, :capital, @t) == 3
    end
  end

  test "ownership public results retain wrappers, record types and structured errors" do
    org =
      Org.new([
        %Party{id: :ann, kind: :person},
        %Party{id: :bob, kind: :person},
        %Party{id: :out, kind: :person},
        Forms.partnership(:co, [{:ann, 2}, {:bob, 1}], preemption: true)
      ])

    assert {:ok, %Org{}} = Ownership.withdraw(org, :ann, :co, @t)
    assert {:error, :not_owner} == Ownership.withdraw(org, :out, :co, @t)
    assert {:error, :units} == Ownership.transfer(org, :ann, :out, :co, :equity, 0, @t)

    assert {:error, {:insufficient, 2}} ==
             Ownership.transfer(org, :ann, :out, :co, :equity, 3, @t)

    assert {:ok, %Org{} = moved, %Ownership.Transfer{} = sale} =
             Ownership.transfer(org, :ann, :out, :co, :equity, 1, @t, price: 10)

    assert sale == %Ownership.Transfer{
             from: :ann,
             to: :out,
             in: :co,
             class: :equity,
             units: 1,
             at: @t,
             price: 10,
             claimants: [:bob]
           }

    assert {:ok, %Org{}} = Ownership.preempt(moved, sale, [:bob])
    assert {:error, :not_entitled} == Ownership.preempt(moved, sale, [])
    assert %Ownership.Partition{} = Ownership.partition(org, :co, :equity, @t)

    assert {:ok, %Org{}, %Ownership.Partition{}} =
             Ownership.dissolve(org, {:co, :owners}, %{ann: :yes}, :equity, @t)

    assert {:error, :not_carried} ==
             Ownership.dissolve(org, {:co, :owners}, %{}, :equity, @t)
  end

  # A translated port must supply its own invariant result here; the oracle is
  # graph membership, not the traversal path chosen by Keel.Graph.cycle/1.
  defp assert_cycle_witnesses(details, edges) do
    assert length(details) == 1
    assert [{:cycle, path}] = details
    assert length(path) >= 2
    assert hd(path) == List.last(path)
    assert Enum.all?(Enum.zip(path, tl(path)), &(&1 in edges))
  end

  test "cycle comparison checks every graph and epoch, including a later disjoint cycle" do
    first = Interval.new(@t, @later)
    second = Interval.new(@later)

    for {name, kind} <- [reports_acyclic: :reports, delegation_acyclic: :delegates] do
      org =
        Org.new([
          Forms.entity(:co),
          for(r <- [:a, :b, :c, :d], do: %Role{id: r, unit: {:co, :hq}}),
          for(
            {a, b, i} <- [{:a, :b, first}, {:b, :a, first}, {:c, :d, second}, {:d, :c, second}],
            do: %Line{from: a, to: b, kind: kind, during: i}
          )
        ])

      for t <- Org.epochs(org) do
        details = apply(Invariants, name, [org, t])

        if Date.compare(t, @t) == :lt do
          assert details == []
        else
          assert_cycle_witnesses(details, Org.graph(org, kind, t))
        end
      end

      cycles = for {^name, t, {:cycle, _}} <- Invariants.check(org), do: t
      assert Enum.sort(cycles, Date) == [@t, @later]
    end
  end

  test "static unit and temporal ownership cycle witnesses follow their directed graphs" do
    org =
      Org.new([
        Forms.entity(:co),
        Forms.entity(:other),
        %Unit{id: :a, of: :co, parent: :b},
        %Unit{id: :b, of: :co, parent: :a},
        %Stake{holder: :co, in: :other, during: Interval.new(@t)},
        %Stake{holder: :other, in: :co, during: Interval.new(@t)}
      ])

    assert_cycle_witnesses(Invariants.unit_forest(org), a: :b, b: :a)

    for t <- Org.epochs(org) do
      details = Invariants.ownership_acyclic(org, t)

      if Date.compare(t, @t) == :lt do
        assert details == []
      else
        assert_cycle_witnesses(details, co: :other, other: :co)
      end
    end

    # Multiple cycles and self-loops permit different valid selections.
    edges = [a: :b, b: :a, c: :c]
    assert_cycle_witnesses([{:cycle, [:a, :b, :a]}], edges)
    assert_cycle_witnesses([{:cycle, [:c, :c]}], edges)

    multi =
      Org.new([
        Forms.entity(:co),
        for(r <- [:a, :b, :c], do: %Role{id: r, unit: {:co, :hq}}),
        for({a, b} <- edges, do: %Line{from: a, to: b})
      ])

    assert_cycle_witnesses(Invariants.reports_acyclic(multi, @t), edges)

    for invalid <- [[], [{:cycle, [:a]}], [{:cycle, [:a, :b]}], [{:cycle, [:a, :c, :a]}]] do
      assert_raise ExUnit.AssertionError, fn -> assert_cycle_witnesses(invalid, edges) end
    end
  end
end
