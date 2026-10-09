defmodule Eatsbot.MoneyDependencyTest do
  use Eatsbot.DataCase, async: true

  alias EatsbotCore.Products.Product

  test "decimal prices retain currency and precision after a database round trip" do
    admin = EatsbotCore.Deliveries.Actors.admin()
    amount = Decimal.new("12.3401")

    product =
      Product.create!(%{name: "Money compatibility", state: :enabled, sku: "MONEY-COMPAT"},
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
        Product.create!(%{name: "Canonical amount", state: :enabled, sku: "MONEY-STRING"},
          actor: admin
        )
        |> Product.update_price!(%{currency: :USD, amount: "12.34"}, actor: admin)

      loaded = Ash.get!(Product, product.id, load: [:prices], actor: admin)
      assert [%{money: %Money{currency: :USD, amount: amount}}] = loaded.prices
      assert Decimal.equal?(amount, Decimal.new("12.34"))
    end)
  end
end
