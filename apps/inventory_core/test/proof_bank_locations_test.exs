defmodule InventoryCore.ProofBankLocationsTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/proof_bank_locations.tsv.gz")
  @ops ~w(receive reserve commit release transfer expire)a
  @statuses ~w(active committed released expired)a

  # The TSV is emitted by formal/lean/InventoryFixtures.lean, evaluating the
  # exact machine-checked transition definition, not a second Elixir model.
  defp command(encoded) do
    [id, version, op, loc, q, expiry] = String.split(encoded, ",")
    op = Enum.find(@ops, &(Atom.to_string(&1) == op))
    q = String.to_integer(q)
    base = %{id: id, expected_version: String.to_integer(version), op: op}

    args =
      case op do
        :receive ->
          %{location: loc, quantity: q}

        :reserve ->
          %{
            location: loc,
            quantity: q,
            reservation_id: "hold-" <> loc,
            expires_at_ms: String.to_integer(expiry)
          }

        :commit ->
          %{reservation_id: "hold-" <> loc, quantity: q}

        :release ->
          %{reservation_id: "hold-" <> loc}

        :transfer ->
          %{from: loc, to: if(loc == "a", do: "b", else: "a"), quantity: q}

        :expire ->
          %{at_ms: q}
      end

    Map.merge(base, args)
  end

  defp slot("none", _loc), do: []

  defp slot(encoded, loc) do
    [status, remaining, expiry] = String.split(encoded, ",")

    [
      {"hold-" <> loc,
       %{
         location: loc,
         status: Enum.find(@statuses, &(Atom.to_string(&1) == status)),
         remaining: String.to_integer(remaining),
         expires_at_ms: String.to_integer(expiry)
       }}
    ]
  end

  defp expected([a, b, ra, rb, watermark, version, seen]) do
    %{
      locations: %{"a" => String.to_integer(a), "b" => String.to_integer(b)},
      reservations: Map.new(slot(ra, "a") ++ slot(rb, "b")),
      expiry_watermark: String.to_integer(watermark),
      version: String.to_integer(version),
      seen:
        seen
        |> String.split(";", trim: true)
        |> Map.new(fn c ->
          c = command(c)
          {c.id, c}
        end)
    }
  end

  defp project(s) do
    s
    |> Map.take([:reservations, :expiry_watermark, :version, :seen])
    |> Map.put(:locations, Map.new(["a", "b"], &{&1, Map.get(s.locations, &1, 0)}))
  end

  defp run_fixture(apply_fun) do
    @fixture
    |> File.read!()
    |> :zlib.gunzip()
    |> String.split("\n", trim: true)
    |> Enum.reduce({nil, nil, 0, MapSet.new()}, fn line, {previous, stock, count, tags} ->
      [trace, encoded, tag | fields] = String.split(String.trim_trailing(line, "\n"), "\t")

      stock =
        if trace == previous,
          do: stock,
          else: elem(InventoryCore.new("merchant", "part", "each"), 1)

      c = command(encoded)
      result = apply_fun.(stock, "merchant", c)

      next =
        case result do
          {:ok, next, actual} ->
            assert Atom.to_string(actual) == tag, "trace #{trace}, command #{encoded}"
            next

          {:error, actual} ->
            assert Atom.to_string(actual) == tag, "trace #{trace}, command #{encoded}"
            stock
        end

      assert project(next) == expected(fields), "trace #{trace}, command #{encoded}"
      assert :ok == InventoryCore.check(next, "merchant")
      tags = MapSet.put(tags, tag)

      tags =
        Enum.reduce(next.reservations, tags, fn {_id, r}, acc ->
          MapSet.put(acc, "status:" <> Atom.to_string(r.status))
        end)

      tags =
        if map_size(next.reservations) == 2 and
             Enum.all?(next.reservations, fn {_, r} -> r.status == :active end),
           do: MapSet.put(tags, "two-active"),
           else: tags

      tags =
        if c.op == :commit and tag == "accepted" and
             next.reservations[c.reservation_id].status == :active,
           do: MapSet.put(tags, "partial-commit"),
           else: tags

      {trace, next, count + 1, tags}
    end)
  end

  test "Lean-generated multi-location traces correspond to the real core" do
    {_, _, count, tags} = run_fixture(&InventoryCore.apply/3)
    assert count == 24_064

    assert MapSet.subset?(
             MapSet.new(
               ~w(status:active status:committed status:released status:expired two-active partial-commit accepted duplicate idempotency_conflict stale_stock_version insufficient_available reservation_not_active reservation_exists unknown_reservation invalid_quantity invalid_expiry nonmonotone_clock)
             ),
             tags
           )
  end

  test "independent mutants are killed by correspondence, not by process errors" do
    # Correct result tags and safe states can still conceal a bad implementation.
    # These valid-shape mutants must trigger assertion failures on state equality.
    mutants = [
      fn before, merchant, c ->
        case InventoryCore.apply(before, merchant, c) do
          {:ok, next, :accepted} when c.op == :commit ->
            {:ok, %{next | locations: before.locations}, :accepted}

          result ->
            result
        end
      end,
      fn before, merchant, c ->
        case InventoryCore.apply(before, merchant, c) do
          {:ok, next, :accepted} when c.op == :release ->
            reservations = Map.delete(next.reservations, c.reservation_id)
            {:ok, %{next | reservations: reservations}, :accepted}

          result ->
            result
        end
      end,
      fn before, merchant, c ->
        case InventoryCore.apply(before, merchant, c) do
          {:ok, next, :duplicate} -> {:ok, %{next | version: next.version + 1}, :duplicate}
          result -> result
        end
      end
    ]

    for mutant <- mutants do
      assert_raise ExUnit.AssertionError, fn -> run_fixture(mutant) end
    end
  end

  test "reconciliation domain rejects additional corrupt shapes without claiming reachability" do
    {:ok, s} = InventoryCore.new("merchant", "part", "each")
    r = %{location: "a", remaining: 0, status: :active, expires_at_ms: 5}

    assert {:error, :stock_invariant_violated} =
             InventoryCore.check(
               %{s | locations: %{"a" => 1}, reservations: %{"hold-a" => r}},
               "merchant"
             )

    assert {:error, :stock_invariant_violated} =
             InventoryCore.check(%{s | locations: %{"a" => -1}}, "merchant")

    # PR #256's orphan-location regression remains in inventory_core_test.exs.
    # check/2 is not a total arbitrary-term validator: a scoped incomplete map
    # raises, and inactive records are not fully shape checked. The refinement
    # map is partial and must reject such input before invoking the core.
    assert_raise KeyError, fn -> InventoryCore.check(%{merchant: "merchant"}, "merchant") end

    assert :ok =
             InventoryCore.check(
               %{s | reservations: %{"bad" => %{status: :released}}},
               "merchant"
             )
  end
end
