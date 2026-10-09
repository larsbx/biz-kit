defmodule Eatsbot.MoneyDependencyTest do
  use Eatsbot.DataCase, async: true

  alias EatsbotCore.Products.Product

  test "nonpositive Decimal and string prices are rejected without persisting a price" do
    admin = EatsbotCore.Deliveries.Actors.admin()

    product =
      Product.create!(
        %{
          name: "Price boundary",
          description: "Decimal comparison fixture",
          state: :enabled,
          sku: "MONEY-BOUNDARY"
        },
        actor: admin
      )

    Enum.each([Decimal.new("-0.01"), Decimal.new("0"), "-0.01", "0"], fn amount ->
      assert {:error, error} =
               Product.update_price(product, %{currency: :USD, amount: amount}, actor: admin)

      assert Exception.message(error) =~ "price amount must be positive"
      assert Ash.get!(Product, product.id, load: [:prices], actor: admin).prices == []
    end)

    assert {:ok, _} =
             Product.update_price(product, %{currency: :USD, amount: "0.01"}, actor: admin)
  end

  test "decimal prices retain currency and precision after a database round trip" do
    admin = EatsbotCore.Deliveries.Actors.admin()
    amount = Decimal.new("12.3401")

    product =
      Product.create!(
        %{
          name: "Money compatibility",
          description: "Fractional price fixture",
          state: :enabled,
          sku: "MONEY-COMPAT"
        },
        actor: admin
      )
      |> Product.update_price!(%{currency: :USD, amount: amount}, actor: admin)

    loaded = Ash.get!(Product, product.id, load: [:prices], actor: admin)
    assert [%{money: %Money{currency: :USD, amount: stored}}] = loaded.prices
    assert Decimal.equal?(stored, amount)
  end

  test "canonical decimal strings stay exact when Gettext presents Spanish" do
    admin = EatsbotCore.Deliveries.Actors.admin()

    Gettext.with_locale("es", fn ->
      product =
        Product.create!(
          %{
            name: "Canonical amount",
            description: "Canonical decimal fixture",
            state: :enabled,
            sku: "MONEY-STRING"
          },
          actor: admin
        )
        |> Product.update_price!(%{currency: :USD, amount: "12.34"}, actor: admin)

      loaded = Ash.get!(Product, product.id, load: [:prices], actor: admin)
      assert [%{money: %Money{currency: :USD, amount: amount}}] = loaded.prices
      assert Decimal.equal?(amount, Decimal.new("12.34"))
    end)
  end
end
