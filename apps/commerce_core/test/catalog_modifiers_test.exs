defmodule CommerceCore.CatalogModifiersTest do
  @moduledoc """
  Modifier groups on catalog products (eatsbot rebuild, slice 2): a quote with a
  selection prices at the variant's price plus the chosen options' deltas, and a
  selection that breaks a group's rules is refused.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CommerceCore.Catalog

  @merchant "pizzeria"

  defp m(minor, currency \\ :USD), do: Money.from_integer(minor, currency)

  defp group(id, min, max, options),
    do: %{
      id: id,
      min: min,
      max: max,
      options: for({oid, delta} <- options, do: %{id: oid, prices: %{USD: m(delta)}})
    }

  defp pizza(groups),
    do: %{
      id: "margherita",
      sku: "MARG",
      visibility: :published,
      prices: %{USD: m(1250)},
      variants: [],
      modifier_groups: groups
    }

  defp size, do: group("size", 1, 1, [{"small", 0}, {"large", 300}])

  defp toppings,
    do: group("toppings", 0, 3, [{"olives", 100}, {"mushrooms", 150}, {"basil", 0}, {"ham", 200}])

  defp catalog(product) do
    {:ok, empty} = Catalog.new(@merchant)
    Catalog.put(empty, @merchant, 0, product)
  end

  defp quote_with(state, selection),
    do: Catalog.quote(state, @merchant, "margherita", nil, :USD, selection)

  describe "quoting with modifiers" do
    setup do
      {:ok, state} = catalog(pizza([size(), toppings()]))
      {:ok, state: state}
    end

    test "the unit price is the base price plus the chosen options", %{state: state} do
      assert {:ok, q} =
               quote_with(state, [
                 {"size", "large"},
                 {"toppings", "olives"},
                 {"toppings", "mushrooms"}
               ])

      assert Money.equal?(q.unit_price, m(1800))
      assert q.modifiers == [{"size", "large"}, {"toppings", "mushrooms"}, {"toppings", "olives"}]
    end

    test "a free option is allowed and adds nothing", %{state: state} do
      assert {:ok, q} = quote_with(state, [{"size", "small"}, {"toppings", "basil"}])
      assert Money.equal?(q.unit_price, m(1250))
    end

    test "each group's minimum and maximum are enforced", %{state: state} do
      assert {:error, {:modifier_count, "size"}} = quote_with(state, [])

      assert {:error, {:modifier_count, "size"}} =
               quote_with(state, [{"size", "small"}, {"size", "large"}])

      four = for t <- ~w(olives mushrooms basil ham), do: {"toppings", t}

      assert {:error, {:modifier_count, "toppings"}} =
               quote_with(state, [{"size", "small"} | four])
    end

    test "unknown, repeated and malformed choices are refused", %{state: state} do
      assert {:error, {:unknown_modifier, "toppings", "pineapple"}} =
               quote_with(state, [{"size", "small"}, {"toppings", "pineapple"}])

      assert {:error, {:unknown_modifier, "crust", "thin"}} =
               quote_with(state, [{"size", "small"}, {"crust", "thin"}])

      assert {:error, {:duplicate_modifier, "toppings", "olives"}} =
               quote_with(state, [
                 {"size", "small"},
                 {"toppings", "olives"},
                 {"toppings", "olives"}
               ])

      assert {:error, :invalid_modifier_selection} = quote_with(state, :large)
      assert {:error, :invalid_modifier_selection} = quote_with(state, [{"size"}])
    end

    test "quote/5 is a quote with no modifiers", %{state: state} do
      assert {:error, {:modifier_count, "size"}} =
               Catalog.quote(state, @merchant, "margherita", nil, :USD)

      {:ok, plain} = catalog(pizza([]))
      assert {:ok, q} = Catalog.quote(plain, @merchant, "margherita", nil, :USD)
      assert Money.equal?(q.unit_price, m(1250))
      assert q.modifiers == []
    end

    test "an option without a price in the quoted currency is refused" do
      euro_only = %{toppings() | max: 1, options: [%{id: "olives", prices: %{EUR: m(100, :EUR)}}]}

      {:ok, state} =
        catalog(%{pizza([size(), euro_only]) | prices: %{USD: m(1250), EUR: m(1150, :EUR)}})

      assert {:error, {:modifier_currency_not_offered, "toppings", "olives"}} =
               quote_with(state, [{"size", "small"}, {"toppings", "olives"}])
    end

    test "another merchant cannot quote with modifiers", %{state: state} do
      assert {:error, :wrong_merchant} =
               Catalog.quote(state, "other", "margherita", nil, :USD, [{"size", "small"}])
    end
  end

  test "malformed modifier groups are refused when the product is put" do
    for groups <- [
          [group("size", 2, 1, [{"a", 0}, {"b", 0}])],
          [group("size", 0, 0, [{"a", 0}])],
          [group("size", 0, 2, [{"a", 0}])],
          [group("size", -1, 1, [{"a", 0}])],
          [group("size", 0, 1, [{"a", -1}])],
          [group("size", 0, 1, [])],
          [group("size", 0, 2, [{"a", 0}, {"a", 1}])],
          [group("size", 0, 1, [{"a", 0}]), group("size", 0, 1, [{"b", 0}])],
          [%{id: "size", min: 0, max: 1, options: [%{id: "a", prices: %{USD: m(1, :EUR)}}]}],
          [%{id: "size", min: 0, max: 1, options: [%{id: "a", prices: %{}}]}],
          [%{id: "", min: 0, max: 1, options: [%{id: "a", prices: %{USD: m(0)}}]}],
          :size
        ] do
      assert {:error, :invalid_modifiers} = catalog(pizza(groups)), inspect(groups)
    end
  end

  # Generators: up to 4 groups of up to 5 options, deltas 0..1000, and a valid selection.
  defp groups_gen do
    gen all(
          specs <- list_of({integer(1..5), integer(0..3), integer(0..5)}, max_length: 4),
          deltas <- list_of(integer(0..1000), length: 20)
        ) do
      specs
      |> Enum.with_index()
      |> Enum.map(fn {{n, min_raw, max_raw}, gi} ->
        max = max(1, min(max_raw, n))
        min = min(min_raw, max)
        options = for oi <- 0..(n - 1), do: {"o#{oi}", Enum.at(deltas, rem(gi * 5 + oi, 20))}
        group("g#{gi}", min, max, options)
      end)
    end
  end

  defp valid_selection(groups) do
    gen all(picks <- fixed_list(Enum.map(groups, &pick_gen/1))) do
      List.flatten(picks)
    end
  end

  defp pick_gen(%{id: gid, min: min, max: max, options: options}) do
    # k distinct options: the first k of a seeded permutation.
    gen all(k <- integer(min..max), seed <- integer()) do
      for %{id: oid} <- options |> Enum.sort_by(&:erlang.phash2({seed, &1.id})) |> Enum.take(k),
          do: {gid, oid}
    end
  end

  property "a valid selection prices at base + Σ deltas, in any order" do
    check all(
            groups <- groups_gen(),
            selection <- valid_selection(groups),
            shuffled <- constant(Enum.shuffle(selection))
          ) do
      {:ok, state} = catalog(pizza(groups))
      {:ok, q} = quote_with(state, selection)
      {:ok, q2} = quote_with(state, shuffled)

      deltas =
        for {gid, oid} <- selection,
            g = Enum.find(groups, &(&1.id == gid)),
            o = Enum.find(g.options, &(&1.id == oid)),
            do: o.prices[:USD]

      expected = Enum.reduce(deltas, m(1250), &Money.add!(&2, &1))
      assert Money.equal?(q.unit_price, expected)
      assert q == q2
      assert q.modifiers == Enum.sort(selection)
    end
  end

  property "a selection outside a group's bounds is refused with that group" do
    check all(
            groups <- filter(groups_gen(), &(&1 != [])),
            selection <- valid_selection(groups),
            gi <- integer(0..(length(groups) - 1))
          ) do
      %{id: gid, min: min, max: max, options: options} = Enum.at(groups, gi)
      others = Enum.reject(selection, &(elem(&1, 0) == gid))

      # Too few, where the group requires any; too many, where options allow it.
      if min > 0 do
        mine = for %{id: oid} <- Enum.take(options, min - 1), do: {gid, oid}
        {:ok, state} = catalog(pizza(groups))
        assert {:error, {:modifier_count, ^gid}} = quote_with(state, others ++ mine)
      end

      if max < length(options) do
        mine = for %{id: oid} <- Enum.take(options, max + 1), do: {gid, oid}
        {:ok, state} = catalog(pizza(groups))
        assert {:error, {:modifier_count, ^gid}} = quote_with(state, others ++ mine)
      end
    end
  end

  property "no call succeeds for another merchant" do
    check all(
            other <- string(:alphanumeric, min_length: 1),
            other != @merchant
          ) do
      {:ok, state} = catalog(pizza([size()]))
      assert {:error, :wrong_merchant} = Catalog.put(state, other, 1, pizza([]))
      assert {:error, :wrong_merchant} = Catalog.fetch(state, other, "margherita")

      assert {:error, :wrong_merchant} =
               Catalog.quote(state, other, "margherita", nil, :USD, [{"size", "small"}])
    end
  end
end
