defmodule Keel.PartitionTest do
  @moduledoc "Division of assets on dissolution (qisma) and compelled sale of what cannot be divided."
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Keel.{Asset, Forms, Invariants, Org, Ownership, Party, Stake}

  @t ~D[2026-06-01]
  @later ~D[2026-09-01]

  defp people(ids), do: for(id <- ids, do: %Party{id: id, kind: :person})

  defp llc(assets) do
    Org.new([
      people([:ann, :bob, :cat]),
      Forms.partnership(:llc, [{:ann, 50}, {:bob, 30}, {:cat, 20}]),
      assets
    ])
  end

  @assets [
    %Asset{id: :cash, of: :llc, quantity: 1_000, divisible: true},
    %Asset{id: :stock, of: :llc, quantity: 7, divisible: true},
    %Asset{id: :truck, of: :llc}
  ]

  test "assets are well-formed nodes of an entity" do
    assert Invariants.check(llc(@assets)) == []
    bad = %Asset{id: :x, of: :ann, quantity: 0}
    assert Enum.any?(Invariants.check(llc([bad])), &match?({:assets, _, _}, &1))
    assert Enum.any?(Invariants.check(llc([bad])), &match?({:references, _, _}, &1))
  end

  test "divisible assets are divided in kind; remainders and indivisibles are sold" do
    plan = Ownership.partition(llc(@assets), :llc, :equity, @t)

    assert plan.allot == %{
             ann: [cash: 500, stock: 3],
             bob: [cash: 300, stock: 2],
             cat: [cash: 200, stock: 1]
           }

    assert plan.sell == [stock: 1, truck: 1]
    assert plan.proceeds == %{ann: {1, 2}, bob: {3, 10}, cat: {1, 5}}
  end

  test "with no owners, nothing is allotted and everything is for sale" do
    org = Org.new([Forms.entity(:e), %Asset{id: :cash, of: :e, quantity: 10, divisible: true}])

    assert %{allot: %{}, sell: [cash: 10], proceeds: %{}} =
             Ownership.partition(org, :e, :equity, @t)
  end

  test "dissolution: any partner of a revocable partnership; history kept" do
    {:ok, org, plan} =
      Ownership.dissolve(llc(@assets), {:llc, :owners}, %{cat: :yes}, :equity, @later)

    assert plan == Ownership.partition(llc(@assets), :llc, :equity, @later)
    assert Org.members(org, {:llc, :owners}, @later) == %{}
    assert Org.members(org, {:llc, :owners}, @t) == %{ann: 50, bob: 30, cat: 20}
  end

  test "dissolution of a binding entity needs its ordinary rule" do
    corp =
      Org.new([
        people([:ann, :bob]),
        Forms.corporation(:co, [{:ann, 900}, {:bob, 100}], [:ann], :ann)
      ])

    assert {:error, :not_carried} =
             Ownership.dissolve(corp, {:co, :owners}, %{bob: :yes}, :common, @later)

    assert {:ok, _, _} = Ownership.dissolve(corp, {:co, :owners}, %{ann: :yes}, :common, @later)
  end

  property "partition conserves every asset and allots each owner the floor of their exact share" do
    check all(
            holdings <- list_of(integer(1..50), min_length: 1, max_length: 6),
            assets <- list_of({integer(1..500), boolean()}, min_length: 1, max_length: 5)
          ) do
      ids = for i <- 1..length(holdings), do: :"p#{i}"

      org =
        Org.new([
          Forms.entity(:e),
          for(
            {id, h} <- Enum.zip(ids, holdings),
            do: [%Party{id: id, kind: :person}, %Stake{holder: id, in: :e, units: h}]
          ),
          for(
            {{q, d}, k} <- Enum.with_index(assets),
            do: %Asset{id: k, of: :e, quantity: q, divisible: d}
          )
        ])

      plan = Ownership.partition(org, :e, :equity, @t)
      total = Enum.sum(holdings)

      for {{q, d}, k} <- Enum.with_index(assets) do
        given = for {_, xs} <- plan.allot, {^k, n} <- xs, do: n
        sold = for {^k, n} <- plan.sell, do: n
        assert Enum.sum(given) + Enum.sum(sold) == q
        if not d, do: assert(given == [])

        for {id, h} <- Enum.zip(ids, holdings), d do
          n =
            with {^k, n} <- List.keyfind(Map.get(plan.allot, id, []), k, 0), do: n, else: (_ -> 0)

          assert n * total <= q * h and q * h < (n + 1) * total
        end
      end

      assert Enum.reduce(Map.values(plan.proceeds), {0, 1}, fn {a, b}, {c, d} ->
               {a * d + c * b, b * d}
             end)
             |> then(fn {a, b} -> a == b end)
    end
  end
end
