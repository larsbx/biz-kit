defmodule ProductTest do
  use Eatsbot.DataCase, async: true

  alias EatsbotCore.Products.{Product, Option, Collection, Type}

  # Product policies authorize on the actor's access level, not on a User record.
  setup do
    {:ok, admin: EatsbotCore.Deliveries.Actors.admin()}
  end

  describe "product lifecycle" do
    test "creates product with discount rules and prices", %{admin: admin} do
      product =
        Product.create!(
          %{
            name: "Test Product",
            description: "Test Description",
            state: :enabled,
            sku: "TEST_SKU",
            discount_rules: [
              %{discount: 50_000, method: :fixed}
            ]
          },
          actor: admin
        )

      assert product.name == "Test Product"
      assert [%{method: :fixed}] = product.discount_rules

      product = Product.update_price!(product, %{amount: 20, currency: :USD}, actor: admin)
      product = Product.update_price!(product, %{amount: 20_000, currency: :CLP}, actor: admin)

      assert Enum.count(product.prices) == 2
    end
  end

  describe "product variants" do
    setup %{admin: admin} do
      product =
        Product.create!(
          %{
            name: "Test Product",
            description: "Description",
            state: :enabled,
            sku: "TEST_SKU",
          },
          actor: admin
        )
        |> Product.update_price!(%{amount: 100, currency: :USD}, actor: admin)

      {:ok, product: product, admin: admin}
    end

    test "generates variants from options", %{product: product, admin: admin} do
      option1 = Product.get_or_create_option!(product, "Color", actor: admin)
      option2 = Product.get_or_create_option!(product, "Size", actor: admin)
      
      Enum.reduce(["Red", "Blue"], option1, fn val, acc ->
        Option.add_value!(acc, val, actor: admin)
      end)

      Enum.reduce(["S", "M"], option2, fn val, acc ->
        Option.add_value!(acc, val, actor: admin)
      end)

      product = Product.generate_variants!(product, actor: admin)

      assert length(product.variants) == 4
    end
  end

  describe "collections" do
    test "adds product to collection", %{admin: admin} do
      product = Product.create!(%{
            name: "Test Product",
            description: "Description",
            state: :enabled,
            sku: "TEST_SKU",
          }, actor: admin)
      %{id: collection_id} = Collection.create!(%{name: "Featured"}, actor: admin)

      updated_product = Product.add_to_collection!(product, collection_id, actor: admin)
      assert [%{id: ^collection_id}] = updated_product.collections
    end
  end

  describe "product types" do
    test "creates new product type", %{admin: admin} do
      {:ok, type} = Ash.create(Type, %{name: "Electronics"}, actor: admin)
      assert type.name == "Electronics"
    end
  end
end

