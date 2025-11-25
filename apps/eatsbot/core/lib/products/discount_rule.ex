defmodule EatsbotCore.Products.DiscountRule do
  @moduledoc """
  Represents a discount rule for products and variants.

  Discount rules define how prices are reduced based on various conditions. The system
  supports multiple discount methods including fixed amounts, percentages, bundle deals
  (x for y), and fixed bundle pricing.

  ## Discount Methods
  - `:fixed` - Reduce price by a fixed amount
  - `:percentage` - Reduce price by a percentage (0.0-1.0)
  - `:x_for_y` - Bundle discount (e.g., "3 for 2")
  - `:x_for_fixed_price` - Fixed bundle pricing (e.g., "3 for $10")

  ## Validation
  - Percentage discounts must be between 0.0 and 1.0
  - Fixed discounts must be positive
  - Bundle quantities (x, y) must be positive integers

  ## Future Enhancement
  Currency-specific rules are planned to allow different discounts per currency.
  """
  use Ash.Resource,
    domain: EatsbotCore.Products,
    extensions: [AshGraphql.Resource],
    data_layer: :embedded

  graphql do
    type :attributes
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :method, :atom do
      public? true
      allow_nil? false
      constraints one_of: [:fixed, :percentage, :x_for_y, :x_for_fixed_price]
    end

    attribute :method_data, :map do
      public? true
      default %{}
    end

    attribute :discount, :decimal do
      public? true
      constraints min: 0
    end

    attribute :enabled, :boolean, public?: true, default: true
    attribute :conditions, {:array, :map}, public?: true, default: []

    # TODO: Add currency-specific discount rules
    # attribute :currencies, {:array, :string}, public?: true, default: []
    # When currencies is empty, rule applies to all currencies
  end

  validations do
    validate fn changeset, _context ->
      method = Ash.Changeset.get_attribute(changeset, :method)
      discount = Ash.Changeset.get_attribute(changeset, :discount)

      cond do
        method == :percentage and discount != nil and (discount < 0 or discount > 1) ->
          {:error,
           field: :discount, message: "percentage discount must be between 0.0 and 1.0"}

        method in [:fixed, :x_for_fixed_price] and discount != nil and discount < 0 ->
          {:error, field: :discount, message: "discount amount must be positive"}

        true ->
          :ok
      end
    end
  end
end
