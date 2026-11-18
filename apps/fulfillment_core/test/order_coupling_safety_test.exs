defmodule FulfillmentCore.OrderCouplingSafetyTest do
  use ExUnit.Case, async: true
  alias FulfillmentCore.OrderCoupling, as: Coupling

  setup_all do
    Code.ensure_loaded!(Coupling)
    :ok
  end

  @path Path.expand("fixtures/eatsbot_characterization/delivery_coupling.jsonl", __DIR__)
  @hash "8da0ca087ebd04ab1c57a8573336473620898a740ba8a8d6415092f021f81187"

  defp records do
    bytes = File.read!(@path)
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @hash
    rows = bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert length(rows) == 307
    rows
  end

  defp atom(s), do: String.to_existing_atom(s)
  defp encode(x) when is_tuple(x), do: x |> Tuple.to_list() |> Enum.map(&encode/1)
  defp encode(x) when is_atom(x), do: Atom.to_string(x)
  defp encode(x), do: x

  test "307 immutable records: alpha/ownership parity and intentional owner refusals" do
    rows = records()

    for r <- rows do
      case r["kind"] do
        "coupled" ->
          assert Coupling.coupled?(atom(r["order"]), r["delivery"]) == r["coupled"]

        "order_edge_owner" ->
          assert encode(Coupling.order_edge_owner(atom(r["from"]), atom(r["to"]))) == r["owner"]

        "delivery_edge_owner" ->
          assert encode(Coupling.delivery_edge_owner(r["from"], r["to"])) == r["owner"]

        "delivery_effect" ->
          from = atom(r["from"])
          to = atom(r["to"])
          result = Coupling.delivery_effect(r["delivery"], from, to)

          if Coupling.order_edge_owner(from, to) == :delivery do
            assert result == {:error, :delivery_owned}
          else
            # The old missing mirror for acceptance on an inconsistent pair also refuses.
            if match?(["raises", _], r["effect"]),
              do: assert(match?({:error, _}, result)),
              else: assert(encode(result) == r["effect"])
          end

        "order_effect" ->
          result = Coupling.order_effect(atom(r["order"]), r["from"], r["to"])

          if Coupling.delivery_edge_owner(r["from"], r["to"]) == :order,
            do: assert(result == {:error, :order_owned}),
            else: assert(encode(result) == r["effect"])
      end
    end

    crashes =
      Enum.filter(
        rows,
        &(&1["kind"] == "delivery_effect" and match?(["raises", _], &1["effect"]))
      )

    assert length(crashes) == 34

    for r <- crashes do
      expected = if r["to"] == "accepted", do: :inconsistent_coupling, else: :delivery_owned

      assert Coupling.delivery_effect(r["delivery"], atom(r["from"]), atom(r["to"])) ==
               {:error, expected}
    end
  end

  test "all consistent recorded source pairs and edges preserve I8 or refuse" do
    rows = records()
    pairs = Enum.filter(rows, &(&1["kind"] == "coupled" and &1["coupled"]))

    for pair <- pairs,
        edge <- Enum.filter(rows, &(&1["kind"] in ["order_edge_owner", "delivery_edge_owner"])) do
      order = atom(pair["order"])
      delivery = pair["delivery"]
      authority = if edge["kind"] == "order_edge_owner", do: :order, else: :delivery
      from = if authority == :order, do: atom(edge["from"]), else: edge["from"]
      to = if authority == :order, do: atom(edge["to"]), else: edge["to"]
      source = if authority == :order, do: order, else: delivery

      if from == source do
        case Coupling.step(order, delivery, authority, to) do
          {:ok, next} -> assert Coupling.coupled?(next.order, next.delivery)
          {:error, reason} -> assert reason in [:order_owned, :delivery_owned]
        end
      end
    end
  end

  test "opposite owner, unknown edges and inconsistent sources refuse without exceptions" do
    assert Coupling.step(:ready, "Ready_To_Pickup", :order, :dispatched) ==
             {:error, :delivery_owned}

    assert Coupling.step(:placed, "Init", :delivery, "Delivery_Aborted") == {:error, :order_owned}
    assert Coupling.step(:ready, "Init", :order, :cancelled) == {:error, :inconsistent_coupling}

    assert Coupling.step(:placed, "Init", :delivery, "Delivery_Done") ==
             {:error, :invalid_transition}

    assert Coupling.step(:placed, "Init", :delivery, "unknown") == {:error, :invalid_transition}
    assert Coupling.step(:placed, "Init", :other, :cancelled) == {:error, :wrong_event_authority}

    assert {:ok, %{order: :cancelled, delivery: "Delivery_Aborted"}} =
             Coupling.step(:ready, "Ready_To_Pickup", :order, :cancelled)

    assert {:ok, %{order: :dispatched, delivery: "In_Delivery"}} =
             Coupling.step(:ready, "Ready_To_Pickup", :delivery, "In_Delivery")
  end

  test "every destination from each consistent source agrees with the pinned owned edge graph" do
    rows = records()
    pairs = Enum.filter(rows, &(&1["kind"] == "coupled" and &1["coupled"]))

    destinations =
      rows |> Enum.filter(&(&1["kind"] == "coupled")) |> Enum.map(& &1["delivery"]) |> Enum.uniq()

    edges =
      Enum.filter(rows, &(&1["kind"] == "delivery_edge_owner" and &1["owner"] == "delivery"))

    for pair <- pairs, to <- destinations do
      result = Coupling.step(atom(pair["order"]), pair["delivery"], :delivery, to)
      allowed = Enum.any?(edges, &(&1["from"] == pair["delivery"] and &1["to"] == to))
      assert match?({:ok, _}, result) == allowed
    end
  end
end
