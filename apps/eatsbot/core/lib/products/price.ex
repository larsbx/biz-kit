defmodule EatsbotCore.Products.Price do
  @moduledoc """
  Represents a price for a product or variant in the Eatsbot e-commerce system.

  Prices are stored with both amount and currency information using the Money type.
  Each product or variant can have multiple prices, one for each supported currency.
  The uniqueness constraint ensures only one price per currency per product/variant.

  ## Key Features
  - Uses PostgreSQL composite Money type for amount and currency
  - Unique price per currency per product or variant
  - Upsert support for price updates
  - Can be associated with either a Product (default price) or Variant (specific price)
  - Currency information extracted via SQL calculation for efficient queries

  ## Identities
  - `:unique_product` - Ensures one price per currency per product
  - `:unique_variant` - Ensures one price per currency per variant
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Products,
    extensions: [AshGraphql.Resource, AshAdmin.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [EatsbotCore.Kafka.AshNotifier]

  graphql do
    type :price
  end

  postgres do
    table "prices"
    repo Eatsbot.Repo

    calculations_to_sql currency: "(money).currency_code"

    references do
      reference :product, on_delete: :delete
      reference :variant, on_delete: :delete
    end
  end

  field_policies do
    field_policy :* do
      description "the rest of the fields don't require any special policies"
      authorize_if always()
    end
  end

  actions do
    defaults [:read, :destroy, update: :*]

    create :create_for_variant do
      upsert? true
      upsert_identity :unique_variant
      accept :*
    end

    create :create_for_product do
      upsert? true
      upsert_identity :unique_product
      accept :*
    end
  end

  policies do
    bypass always() do
      description "admin has access to every action"
      authorize_if actor_attribute_equals(:access_level, :admin)
    end

    policy action_type(:read) do
      description "read access is always allowed"
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :money, :money, public?: true, allow_nil?: false

    timestamps()
  end

  validations do
    validate fn changeset, _context ->
      case Ash.Changeset.get_attribute(changeset, :money) do
        %Money{amount: amount} when amount <= 0 ->
          {:error, field: :money, message: "price amount must be positive"}

        _ ->
          :ok
      end
    end
  end

  relationships do
    belongs_to :product, EatsbotCore.Products.Product do
      public? true
    end

    belongs_to :variant, EatsbotCore.Products.Variant do
      public? true
    end
  end

  calculations do
    calculate :currency, :string, expr(fragment("(money).currency_code"))
  end

  identities do
    identity :unique_product, [:currency, :product_id]
    identity :unique_variant, [:currency, :variant_id]
  end
end
