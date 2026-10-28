defmodule EatsbotCore.Carts.CartLine do
  @moduledoc """
  Represents a line item in a shopping cart.

  A CartLine associates a product variant with a specific cart, including the quantity
  and any custom notes. Each cart can only have one line per variant (enforced by identity),
  so adding the same variant again updates the existing line quantity.

  ## Key Features
  - Unique variant per cart (upsert behavior)
  - Quantity validation (minimum 1)
  - Optional customer notes for customization requests
  - Automatic subtotal calculation before and after discounts
  - Real-time updates via PubSub notifications

  ## Calculations
  - `subtotal_before_discount` - Base price × quantity in cart's currency
  - `subtotal` - Final price after applying discount rules
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Carts,
    extensions: [AshGraphql.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub, EatsbotCore.Kafka.AshNotifier]

  graphql do
    type :cart_line
  end

  postgres do
    table "cart_lines"
    repo Eatsbot.Repo
  end

  policies do
    bypass always() do
      authorize_if always()
    end
  end

  field_policies do
    field_policy :* do
      description "the rest of the fields don't require any special policies"
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :quantity, :integer,
      public?: true,
      allow_nil?: false,
      constraints: [min: 1, max: 999]

    attribute :notes, :string, public?: true

    timestamps()
  end

  relationships do
    belongs_to :variant, EatsbotCore.Products.Variant, public?: true, allow_nil?: false
    belongs_to :cart, EatsbotCore.Carts.Cart, public?: true, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, update: :*]

    create :create do
      primary? true
      upsert? true
      upsert_identity :unique_variant
      accept :*
    end
  end

  identities do
    identity :unique_variant, [:variant_id, :cart_id]
  end

  calculations do
    calculate :subtotal_before_discount,
              :money,
              expr(
                first(variant.prices,
                  query: [
                    filter: currency == variant.cart_lines.cart.currency,
                    load: [variant: [cart_lines: [:cart]]]
                  ],
                  field: :money
                ) *
                  quantity
              )

    calculate :subtotal,
              :money,
              EatsbotCore.Carts.DiscountsCalculation
  end
end
