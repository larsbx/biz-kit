defmodule CommerceCore.OrderPipelineTest do
  @moduledoc """
  I₂ as a property of `Pricing`, and the rules composed as checkout will compose them
  (eatsbot rebuild, slice 2): quote each line with its modifiers, tax the line
  subtotals, then price the order with that tax.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CommerceCore.{Catalog, Pricing, Tax}

  defp m(minor, currency \\ :USD), do: Money.from_integer(minor, currency)
  defp minor(money), do: money |> Money.to_integer_exp() |> elem(1)

  property "I₂: line subtotals and the total follow from the inputs, or the total is refused" do
    check all(
            currency <- member_of([:USD, :EUR, :CLP]),
            raw <-
              list_of({integer(0..5_000), integer(1..6), integer(0..100)},
                min_length: 1,
                max_length: 6
              ),
            [discount, tax, fee, tip] <- list_of(integer(0..2_000), length: 4)
          ) do
      lines =
        for {unit, qty, pct} <- raw,
            do: %{
              unit_price: m(unit, currency),
              quantity: qty,
              discount: m(div(unit * qty * pct, 100), currency)
            }

      adjustments = %{
        discount_total: m(discount, currency),
        tax_total: m(tax, currency),
        delivery_fee: m(fee, currency),
        tip: m(tip, currency)
      }

      subtotals = for {unit, qty, pct} <- raw, do: unit * qty - div(unit * qty * pct, 100)
      expected = Enum.sum(subtotals) - discount + tax + fee + tip

      case Pricing.price(currency, lines, adjustments) do
        {:ok, priced} ->
          assert Enum.map(priced.lines, &minor(&1.subtotal)) == subtotals
          assert minor(priced.subtotal) == Enum.sum(subtotals)
          assert minor(priced.total) == expected
          assert expected >= 0

        {:error, :negative_total} ->
          assert expected < 0
      end
    end
  end

  defp menu do
    {:ok, empty} = Catalog.new("pizzeria")

    {:ok, catalog} =
      Catalog.put(empty, "pizzeria", 0, %{
        id: "margherita",
        sku: "MARG",
        visibility: :published,
        prices: %{USD: m(1250)},
        modifier_groups: [
          %{
            id: "size",
            min: 1,
            max: 1,
            options: [
              %{id: "small", prices: %{USD: m(0)}},
              %{id: "large", prices: %{USD: m(300)}}
            ]
          },
          %{
            id: "extras",
            min: 0,
            max: 2,
            options: [
              %{id: "olives", prices: %{USD: m(100)}},
              %{id: "ham", prices: %{USD: m(225)}}
            ]
          }
        ]
      })

    catalog
  end

  property "quote → tax → price: the order's total is its lines, their tax, fee and tip" do
    catalog = menu()

    check all(
            picks <-
              list_of(
                {member_of(~w(small large)),
                 member_of([[], ["olives"], ["ham"], ["olives", "ham"]]), integer(1..4)},
                min_length: 1,
                max_length: 5
              ),
            rate_ppm <- integer(0..150_000),
            fee <- integer(0..800),
            tip <- integer(0..1_500)
          ) do
      lines =
        for {size, extras, qty} <- picks do
          {:ok, q} =
            Catalog.quote(catalog, "pizzeria", "margherita", nil, :USD, [
              {"size", size} | Enum.map(extras, &{"extras", &1})
            ])

          %{unit_price: q.unit_price, quantity: qty, discount: m(0)}
        end

      bases = Enum.map(lines, &Money.mult!(&1.unit_price, &1.quantity))
      rate = Decimal.div(Decimal.new(rate_ppm), Decimal.new(1_000_000))
      {:ok, tax} = Tax.flat(:USD, %{rate: rate, fee_taxable?: false}, bases, m(fee))

      {:ok, priced} =
        Pricing.price(:USD, lines, %{
          discount_total: m(0),
          tax_total: tax.total,
          delivery_fee: m(fee),
          tip: m(tip)
        })

      # I₇ and I₂ together: every tax share is accounted for, and nothing else changes the total.
      assert Enum.sum(Enum.map(tax.lines, &minor/1)) + minor(tax.fee) == minor(tax.total)

      assert minor(priced.total) ==
               Enum.sum(Enum.map(bases, &minor/1)) + minor(tax.total) + fee + tip
    end
  end
end
